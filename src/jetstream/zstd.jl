#= jetstream/zstd.jl — Zstandard frame decompression/compression via Zstd_jll (with custom dictionary support) =#

const _ZSTD_MAGIC = (0x28, 0xb5, 0x2f, 0xfd)
const _ZSTD_CONTENTSIZE_UNKNOWN = typemax(UInt64)
const _ZSTD_CONTENTSIZE_ERROR = typemax(UInt64) - UInt64(1)

mutable struct _ZstdInBuffer
    src::Ptr{Cvoid}
    size::Csize_t
    pos::Csize_t
end

mutable struct _ZstdOutBuffer
    dst::Ptr{Cvoid}
    size::Csize_t
    pos::Csize_t
end

_zstd_is_error(code::Csize_t)::Bool =
    ccall((:ZSTD_isError, libzstd), Cuint, (Csize_t,), code) != 0

function _zstd_error_name(code::Csize_t)::String
    ptr = ccall((:ZSTD_getErrorName, libzstd), Cstring, (Csize_t,), code)
    return ptr == C_NULL ? "unknown zstd error" : unsafe_string(ptr)
end

function _is_zstd_frame(bytes::AbstractVector{UInt8})::Bool
    length(bytes) >= 4 || return false
    @inbounds return bytes[1] == _ZSTD_MAGIC[1] &&
                     bytes[2] == _ZSTD_MAGIC[2] &&
                     bytes[3] == _ZSTD_MAGIC[3] &&
                     bytes[4] == _ZSTD_MAGIC[4]
end

"""
    ZstdDecompressor(; dictionary=nothing)

Reusable thread-safe Zstandard decompressor backed by `Zstd_jll.libzstd`.
Supports both standard zstd frames and custom-dictionary frames (such as
Bluesky Jetstream's `compress=true` dictionary).
"""
mutable struct ZstdDecompressor
    dctx::Ptr{Cvoid}
    ddict::Ptr{Cvoid}
    const lock::ReentrantLock

    function ZstdDecompressor(; dictionary::Union{AbstractVector{UInt8}, Nothing} = nothing)
        dctx = ccall((:ZSTD_createDCtx, libzstd), Ptr{Cvoid}, ())
        dctx == C_NULL && error("ZSTD_createDCtx failed")
        ddict = C_NULL
        if !isnothing(dictionary) && !isempty(dictionary)
            dict_vec = Vector{UInt8}(dictionary)
            ddict = GC.@preserve dict_vec ccall(
                (:ZSTD_createDDict, libzstd),
                Ptr{Cvoid},
                (Ptr{Cvoid}, Csize_t),
                pointer(dict_vec),
                Csize_t(length(dict_vec)),
            )
            if ddict == C_NULL
                ccall((:ZSTD_freeDCtx, libzstd), Csize_t, (Ptr{Cvoid},), dctx)
                error("ZSTD_createDDict failed")
            end
        end
        obj = new(dctx, ddict, ReentrantLock())
        finalizer(obj) do d
            if d.ddict != C_NULL
                ccall((:ZSTD_freeDDict, libzstd), Csize_t, (Ptr{Cvoid},), d.ddict)
                d.ddict = C_NULL
            end
            if d.dctx != C_NULL
                ccall((:ZSTD_freeDCtx, libzstd), Csize_t, (Ptr{Cvoid},), d.dctx)
                d.dctx = C_NULL
            end
            return nothing
        end
        return obj
    end
end

function _decompress_streaming(d::ZstdDecompressor, src::Vector{UInt8}, max_bytes::Int)::Vector{UInt8}
    # Reset session & attach optional dictionary
    rc = ccall((:ZSTD_DCtx_reset, libzstd), Csize_t, (Ptr{Cvoid}, Cint), d.dctx, Cint(1)) # ZSTD_reset_session_only = 1
    _zstd_is_error(rc) && error("ZSTD_DCtx_reset failed: $(_zstd_error_name(rc))")
    if d.ddict != C_NULL
        rc2 = ccall((:ZSTD_DCtx_refDDict, libzstd), Csize_t, (Ptr{Cvoid}, Ptr{Cvoid}), d.dctx, d.ddict)
        _zstd_is_error(rc2) && error("ZSTD_DCtx_refDDict failed: $(_zstd_error_name(rc2))")
    end

    out_io = IOBuffer()
    chunk = Vector{UInt8}(undef, 16384)
    total = 0
    GC.@preserve src chunk begin
        inbuf = _ZstdInBuffer(pointer(src), Csize_t(length(src)), Csize_t(0))
        while inbuf.pos < inbuf.size
            outbuf = _ZstdOutBuffer(pointer(chunk), Csize_t(length(chunk)), Csize_t(0))
            ret = ccall(
                (:ZSTD_decompressStream, libzstd),
                Csize_t,
                (Ptr{Cvoid}, Ref{_ZstdOutBuffer}, Ref{_ZstdInBuffer}),
                d.dctx,
                outbuf,
                inbuf,
            )
            _zstd_is_error(ret) && error("ZSTD_decompressStream failed: $(_zstd_error_name(ret))")
            n = Int(outbuf.pos)
            if n > 0
                total += n
                total > max_bytes && error("Decompressed zstd frame exceeds max_bytes ($max_bytes)")
                write(out_io, view(chunk, 1:n))
            end
            ret == 0 && break
        end
    end
    return take!(out_io)
end

"""
    zstd_decompress(d::ZstdDecompressor, data::AbstractVector{UInt8}; max_bytes=16*1024*1024) -> Vector{UInt8}
    zstd_decompress(data::AbstractVector{UInt8}; dictionary=nothing, max_bytes=16*1024*1024) -> Vector{UInt8}

Decompress a Zstandard-compressed byte vector (supporting both single-shot known-size
frames and streaming frames, with or without a custom dictionary).
"""
function zstd_decompress(
    d::ZstdDecompressor,
    data::AbstractVector{UInt8};
    max_bytes::Int = 16 * 1024 * 1024,
)::Vector{UInt8}
    src = data isa Vector{UInt8} ? data : Vector{UInt8}(data)
    isempty(src) && throw(ArgumentError("Empty zstd frame"))
    return Base.@lock d.lock begin
        fsize = GC.@preserve src ccall(
            (:ZSTD_getFrameContentSize, libzstd),
            UInt64,
            (Ptr{Cvoid}, Csize_t),
            pointer(src),
            Csize_t(length(src)),
        )
        fsize == _ZSTD_CONTENTSIZE_ERROR && error("Invalid Zstandard frame header")
        if fsize == _ZSTD_CONTENTSIZE_UNKNOWN
            return _decompress_streaming(d, src, max_bytes)
        end
        Int(fsize) > max_bytes && error("Decompressed zstd frame size ($fsize) exceeds max_bytes ($max_bytes)")
        dst = Vector{UInt8}(undef, Int(fsize))
        n = GC.@preserve src dst begin
            if d.ddict != C_NULL
                ccall(
                    (:ZSTD_decompress_usingDDict, libzstd),
                    Csize_t,
                    (Ptr{Cvoid}, Ptr{Cvoid}, Csize_t, Ptr{Cvoid}, Csize_t, Ptr{Cvoid}),
                    d.dctx,
                    pointer(dst),
                    Csize_t(length(dst)),
                    pointer(src),
                    Csize_t(length(src)),
                    d.ddict,
                )
            else
                ccall(
                    (:ZSTD_decompressDCtx, libzstd),
                    Csize_t,
                    (Ptr{Cvoid}, Ptr{Cvoid}, Csize_t, Ptr{Cvoid}, Csize_t),
                    d.dctx,
                    pointer(dst),
                    Csize_t(length(dst)),
                    pointer(src),
                    Csize_t(length(src)),
                )
            end
        end
        _zstd_is_error(n) && error("Zstandard decompression failed: $(_zstd_error_name(n))")
        length(dst) == Int(n) ? dst : resize!(dst, Int(n))
    end
end

function zstd_decompress(
    data::AbstractVector{UInt8};
    dictionary::Union{AbstractVector{UInt8}, Nothing} = nothing,
    max_bytes::Int = 16 * 1024 * 1024,
)::Vector{UInt8}
    return zstd_decompress(ZstdDecompressor(; dictionary), data; max_bytes)
end

"""
    zstd_compress(data::Union{AbstractVector{UInt8}, AbstractString}; dictionary=nothing, level::Int=3) -> Vector{UInt8}

Compress `data` into a Zstandard frame (optionally using a custom `dictionary`).
"""
function zstd_compress(
    data::Union{AbstractVector{UInt8}, AbstractString};
    dictionary::Union{AbstractVector{UInt8}, Nothing} = nothing,
    level::Int = 3,
)::Vector{UInt8}
    src = data isa AbstractString ? Vector{UInt8}(codeunits(String(data))) :
          (data isa Vector{UInt8} ? data : Vector{UInt8}(data))
    bound = ccall((:ZSTD_compressBound, libzstd), Csize_t, (Csize_t,), Csize_t(length(src)))
    dst = Vector{UInt8}(undef, Int(bound))
    cctx = ccall((:ZSTD_createCCtx, libzstd), Ptr{Cvoid}, ())
    cctx == C_NULL && error("ZSTD_createCCtx failed")
    cdict = C_NULL
    try
        n = if !isnothing(dictionary) && !isempty(dictionary)
            dict_vec = Vector{UInt8}(dictionary)
            cdict = GC.@preserve dict_vec ccall(
                (:ZSTD_createCDict, libzstd),
                Ptr{Cvoid},
                (Ptr{Cvoid}, Csize_t, Cint),
                pointer(dict_vec),
                Csize_t(length(dict_vec)),
                Cint(level),
            )
            cdict == C_NULL && error("ZSTD_createCDict failed")
            GC.@preserve src dst ccall(
                (:ZSTD_compress_usingCDict, libzstd),
                Csize_t,
                (Ptr{Cvoid}, Ptr{Cvoid}, Csize_t, Ptr{Cvoid}, Csize_t, Ptr{Cvoid}),
                cctx,
                pointer(dst),
                Csize_t(length(dst)),
                pointer(src),
                Csize_t(length(src)),
                cdict,
            )
        else
            GC.@preserve src dst ccall(
                (:ZSTD_compressCCtx, libzstd),
                Csize_t,
                (Ptr{Cvoid}, Ptr{Cvoid}, Csize_t, Ptr{Cvoid}, Csize_t, Cint),
                cctx,
                pointer(dst),
                Csize_t(length(dst)),
                pointer(src),
                Csize_t(length(src)),
                Cint(level),
            )
        end
        _zstd_is_error(n) && error("Zstandard compression failed: $(_zstd_error_name(n))")
        return resize!(dst, Int(n))
    finally
        cdict != C_NULL && ccall((:ZSTD_freeCDict, libzstd), Csize_t, (Ptr{Cvoid},), cdict)
        ccall((:ZSTD_freeCCtx, libzstd), Csize_t, (Ptr{Cvoid},), cctx)
    end
end
