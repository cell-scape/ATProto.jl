# Shared types for the DAG-CBOR data model.

"""
    DagBytes(bytes) <: Any

A byte-string value in the DAG-CBOR data model. Wraps `Vector{UInt8}` so
that byte strings stay distinct from arrays of small integers (in TS the
`Uint8Array` type plays this role; in Julia `Vector{UInt8}` alone would be
ambiguous with arrays of CBOR integers).
"""
struct DagBytes
    bytes::Vector{UInt8}

    function DagBytes(bytes::AbstractVector{UInt8})
        return new(copy(bytes))
    end
end

DagBytes(d::DagBytes) = d

Base.:(==)(a::DagBytes, b::DagBytes) = a.bytes == b.bytes
Base.hash(d::DagBytes, h::UInt) = hash(d.bytes, h)
Base.length(d::DagBytes) = length(d.bytes)
Base.show(io::IO, d::DagBytes) = print(io, "DagBytes(", bytes2hex(d.bytes), ")")
