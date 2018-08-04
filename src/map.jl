const BLOCKSIZE = 1024

function Base.map!(f::F, b::StridedView{<:Any,N}, a1::StridedView{<:Any,N}, A::Vararg{StridedView{<:Any,N}}) where {F,N}
    dims = size(b)

    # Check dimesions
    size(a1) == dims || throw(DimensionMismatch())
    for a in A
        size(a) == dims || throw(DimensionMismatch())
    end

    any(isequal(0), dims) && return b # don't do anything

    # Fuse dimensions if possible: assume that at least one array (e.g. output b) has its strides sorted
    allstrides = map(strides, (b, a1, A...))
    @inbounds for i = N:-1:2
        merge = true
        for s in allstrides
            if s[i] != dims[i-1]*s[i-1]
                merge = false
                break
            end
        end
        if merge
            dims = TupleTools.setindex(dims, dims[i-1]*dims[i], i-1)
            dims = TupleTools.setindex(dims, 1, i)
        end
    end

    _map!(f, dims, allstrides, (b, a1, A...))

    return b
end

function _map!(f::F, dims::NTuple{N,Int}, strides::NTuple{M, NTuple{N,Int}}, arrays::NTuple{M,StridedView}) where {F,N,M}
    i = findfirst(isequal(1), dims)
    if !(i isa Nothing) # delete indices of size 1
        newdims = TupleTools.deleteat(dims, i)
        newstrides = broadcast(TupleTools.deleteat, strides, (i,))
        _map!(f, newdims, newstrides, arrays)
    else
        # sort order of loops/dimensions by modelling the importance of each dimension
        g = ceil(Int, log2(M+2)) # to account for the fact that there are M arrays, where the first one is counted with a factor 2
        importance = 2 .* ( 1 .<< (g.*(N .- indexorder(strides[1]))))  # first array is output and is more important by a factor 2
        for k = 2:M
            importance = importance .+ ( 1 .<< (g.*(N .- indexorder(strides[k]))))
        end

        p = TupleTools.sortperm(importance, rev = true)

        dims = TupleTools.getindices(dims, p)
        strides = broadcast(TupleTools.getindices, strides, (p,))
        offsets = map(offset, arrays)

        if all(l -> l<=BLOCKSIZE, broadcast(_length, (dims,), strides))
            _map_kernel!(f, dims, dims, arrays, strides, offsets)
        else
            minstrides = map(min, strides...)
            mincosts = map(a->ifelse(iszero(a), 1, a << 1), minstrides)
            blocks = _computeblocks(dims, mincosts, strides)

            if Threads.nthreads() == 1 || Threads.in_threaded_loop[] || prod(dims) < Threads.nthreads()*prod(blocks)
                _map_kernel!(f, dims, blocks, arrays, strides, offsets)
            else
                mincosts = mincosts .* .!(iszero.(strides[1]))
                # make cost of dimensions with zero stride in output array (reduction dimensions),
                # so that they are not divided in threading (which would lead to race errors)

                n = Threads.nthreads()
                threadblocks, threadoffsets = _computethreadblocks(n, dims, mincosts, strides, offsets)
                _map_threaded!(threadblocks, threadoffsets, f, blocks, arrays, strides)
            end
        end
    end
    return
end

@noinline function _map_threaded!(threadblocks, threadoffsets, f::F, blocks::NTuple{N,Int}, arrays::NTuple{M,StridedView}, strides::NTuple{M,NTuple{N,Int}}) where {F,N,M}
    @inbounds Threads.@threads for i = 1:length(threadblocks)
        _map_kernel!(f, threadblocks[i], blocks, arrays, strides, threadoffsets[i])
    end
end

@generated function _map_kernel!(f::F, dims::NTuple{N,Int}, blocks::NTuple{N,Int}, arrays::NTuple{M,StridedView}, strides::NTuple{M,NTuple{N,Int}}, offsets::NTuple{M,Int}) where {F,N,M}
    blockloopvars = [Symbol("J$i") for i = 1:N]
    blockdimvars = [Symbol("d$i") for i = 1:N]
    innerloopvars = [Symbol("j$i") for i = 1:N]

    stridevars = [Symbol("stride_$(i)_$(j)") for i = 1:N, j = 1:M]
    Ivars = [Symbol("I$j") for j = 1:M]
    Avars = [Symbol("A$j") for j = 1:M]
    pre1 = Expr(:block, [:($(Avars[j]) = arrays[$j]) for j = 1:M]...)
    pre2 = Expr(:block, [:($(stridevars[i,j]) = strides[$j][$i]) for i = 1:N, j=1:M]...)
    pre3 = Expr(:block, [:($(Ivars[j]) = offsets[$j]+1) for j = 1:M]...)

    ex = :(A1[ParentIndex($(Ivars[1]))] = f($([:($(Avars[j])[ParentIndex($(Ivars[j]))]) for j = 2:M]...)))
    i = 1
    if N >= 1
        ex = quote
            @simd for $(innerloopvars[i]) = Base.OneTo($(blockdimvars[i]))
                $ex
                $(Expr(:block, [:($(Ivars[j]) += $(stridevars[i,j])) for j = 1:M]...))
            end
            $(Expr(:block, [:($(Ivars[j]) -=  $(blockdimvars[i]) * $(stridevars[i,j])) for j = 1:M]...))
        end
    end
    for i = 2:N
        ex = quote
            for $(innerloopvars[i]) = Base.OneTo($(blockdimvars[i]))
                $ex
                $(Expr(:block, [:($(Ivars[j]) += $(stridevars[i,j])) for j = 1:M]...))
            end
            $(Expr(:block, [:($(Ivars[j]) -=  $(blockdimvars[i]) * $(stridevars[i,j])) for j = 1:M]...))
        end
    end
    for i2 = 1:N
        ex = quote
            for $(blockloopvars[i2]) = 1:blocks[$i2]:dims[$i2]
                $(blockdimvars[i2]) = min(blocks[$i2], dims[$i2]-$(blockloopvars[i2])+1)
                $ex
                $(Expr(:block, [:($(Ivars[j]) +=  $(blockdimvars[i2]) * $(stridevars[i2,j])) for j = 1:M]...))
            end
            $(Expr(:block, [:($(Ivars[j]) -=  dims[$i2] * $(stridevars[i2,j])) for j = 1:M]...))
        end
    end
    quote
        $pre1
        $pre2
        $pre3
        @inbounds $ex
        return A1
    end
end

function indexorder(strides::NTuple{N,Int}) where {N}
    # returns order such that strides[i] is the order[i]th smallest element of strides, not counting zero strides
    # zero strides have order N
    return ntuple(Val(N)) do i
        si = strides[i]
        si == 0 && return N
        k = 1
        for s in strides
            if s != 0 && s < si
                k += 1
            end
        end
        return k
    end
end

_length(dims::Tuple, strides::Tuple) = ifelse(iszero(strides[1]), 1, dims[1]) * _length(Base.tail(dims), Base.tail(strides))
_length(dims::Tuple{}, strides::Tuple{}) = 1
_maxlength(dims::Tuple, strides::Tuple{Vararg{Tuple}}) = maximum(broadcast(_length, (dims,), strides))

function _lastargmax(t::Tuple)
    i = 1
    for j = 2:length(t)
        @inbounds if t[j] >= t[i]
            i = j
        end
    end
    return i
end

_computeblocks(dims::Tuple{}, costs::Tuple{}, strides::Tuple{Vararg{Tuple{}}}, blocksize::Int = BLOCKSIZE) = ()
function _computeblocks(dims::NTuple{N,Int}, costs::NTuple{N,Int}, strides::Tuple{Vararg{NTuple{N,Int}}}, blocksize::Int = BLOCKSIZE) where {N}
    if _maxlength(dims, strides) <= blocksize
        return dims
    elseif all(isequal(1), map(TupleTools.argmin, strides))
        return (dims[1], _computeblocks(tail(dims), tail(costs), map(tail, strides), div(blocksize, dims[1]))...)
    elseif blocksize == 0
        return ntuple(n->1, StaticLength(N))
    else
        blocks = dims
        while _maxlength(blocks, strides) >= 2*blocksize
            i = _lastargmax((blocks .- 1) .* costs)
            blocks = TupleTools.setindex(blocks, (blocks[i]+1)>>1, i)
        end
        while _maxlength(blocks, strides) > blocksize
            i = _lastargmax((blocks .- 1) .* costs)
            blocks = TupleTools.setindex(blocks, blocks[i]-1, i)
        end
        return blocks
    end
end

function _computethreadblocks(n::Int, dims::NTuple{N,Int}, costs::NTuple{N,Int}, strides::NTuple{M,NTuple{N,Int}}, offsets::NTuple{M,Int}) where {N,M}
    factors = reverse!(simpleprimefactorization(n))
    threadblocks = [dims]
    threadoffsets = [offsets]
    for k in factors
        l = length(threadblocks)
        for j = 1:l
            dims = popfirst!(threadblocks)
            offsets = popfirst!(threadoffsets)
            i = _lastargmax((dims .- k) .* costs)
            ndi = div(dims[i], k)
            newdims = setindex(dims, ndi, i)
            stridesi = getindex.(strides, i)
            for m = 1:k-1
                push!(threadblocks, newdims)
                push!(threadoffsets, offsets)
                offsets = offsets .+ ndi .* stridesi
            end
            ndi = dims[i]-(k-1)*ndi
            newdims = setindex(dims, ndi, i)
            push!(threadblocks, newdims)
            push!(threadoffsets, offsets)
        end
    end
    return threadblocks, threadoffsets
end
