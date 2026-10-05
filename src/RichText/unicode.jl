# Unicode string helpers. Julia strings are UTF-8 natively, so byte indices
# are the default — this type mainly exists to make the facet API explicit
# about which coordinate system it uses (UTF-8 bytes, like atproto facets).

"""
    UnicodeString(text)

A string wrapper for richtext handling. `length` and slicing use UTF-8 byte
indices (the coordinate system of atproto facets); `grapheme_length` counts
user-perceived characters.
"""
struct UnicodeString
    text::String

    UnicodeString(text::AbstractString) = new(String(text))
end

Base.string(us::UnicodeString) = us.text
Base.show(io::IO, us::UnicodeString) = print(io, us.text)

"UTF-8 byte length (what facet indices count)."
byte_length(us::UnicodeString) = ncodeunits(us.text)
Base.length(us::UnicodeString) = byte_length(us)

"User-perceived character count."
grapheme_length(us::UnicodeString) = length(collect(Base.Unicode.graphemes(us.text)))

"""
    slice(us, start_byte, end_byte) -> String

Extract `[start_byte, end_byte)` as UTF-8 bytes. Throws on invalid
boundaries (must be codeunit indices).
"""
function slice(us::UnicodeString, start_byte::Int, end_byte::Int)::String
    # facet indices are 0-based bytes; Julia strings are 1-based
    from = start_byte + 1
    to = end_byte
    (from <= to <= ncodeunits(us.text)) || return ""
    return String(collect(codeunits(us.text))[from:to])
end

"Convert a UTF-16 code-unit index to a UTF-8 byte index (for JS interop)."
function utf16_index_to_utf8_index(us::UnicodeString, i16::Int)::Int
    i8 = 0
    i = 0
    while i < i16 && i8 < ncodeunits(us.text)
        i8 = nextind(us.text, i8)
        c = codeunit(us.text, i8)
        if c >= 0xf0
            i += 2  # 4-byte UTF-8 = 2 UTF-16 units
        else
            i += 1
        end
        # combining chars: skip grapheme-internal units
    end
    return i8
end
