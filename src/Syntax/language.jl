# BCP 47 language tag validation. Port of `packages/syntax/src/language.ts`.

const BCP47_REGEXP = r"\A((?<grandfathered>(en-GB-oed|i-ami|i-bnn|i-default|i-enochian|i-hak|i-klingon|i-lux|i-mingo|i-navajo|i-pwn|i-tao|i-tay|i-tsu|sgn-BE-FR|sgn-BE-NL|sgn-CH-DE)|(art-lojban|cel-gaulish|no-bok|no-nyn|zh-guoyu|zh-hakka|zh-min|zh-min-nan|zh-xiang))|((?<language>([A-Za-z]{2,3}(-(?<extlang>[A-Za-z]{3}(-[A-Za-z]{3}){0,2}))?)|[A-Za-z]{4}|[A-Za-z]{5,8})(-(?<script>[A-Za-z]{4}))?(-(?<region>[A-Za-z]{2}|[0-9]{3}))?(-(?<variant>[A-Za-z0-9]{5,8}|[0-9][A-Za-z0-9]{3}))*(-(?<extension>[0-9A-WY-Za-wy-z](-[A-Za-z0-9]{2,8})+))*(-(?<privateUseA>[xX](-[A-Za-z0-9]{1,8})+))?)|(?<privateUseB>[xX](-[A-Za-z0-9]{1,8})+))\z"

"""
    is_valid_language(s) -> Bool

Return `true` if `s` is a well-formed BCP 47 language tag (RFC 5646 §2.1
grammar only). Legacy forms with upper-case primary subtags (e.g. `"JA"`)
still validate; use [`parse_language`](@ref) for strict validation.
"""
is_valid_language(s::AbstractString)::Bool = occursin(BCP47_REGEXP, s)

"""
    parse_language(s) -> Union{NamedTuple, Nothing}

Strictly parse a BCP 47 language tag, returning a named tuple with fields
`grandfathered`, `language`, `extlang`, `script`, `region`, `variant`,
`extension`, `privateUse` (each a `String` or `nothing`), or `nothing` when
`s` is not a strictly-valid tag.

Stricter than [`is_valid_language`](@ref): the primary subtag must be a
lower-case 2–3 letter code, and repeated variant/extension-singleton subtags
are rejected (RFC 5646 §4.1) — matching the atproto interop suite.
"""
function parse_language(s::AbstractString)::Union{NamedTuple,Nothing}
    m = match(BCP47_REGEXP, s)
    m === nothing && return nothing
    _has_duplicate_variant_or_singleton(s, m) && return nothing
    # strict: primary subtag must be lower-case 2-3 letters
    language = m[:language]
    if language !== nothing
        primary = first(split(language, "-"))
        occursin(r"\A[a-z]{2,3}\z", primary) || return nothing
    end
    return (;
        grandfathered = m[:grandfathered],
        language = m[:language],
        extlang = m[:extlang],
        script = m[:script],
        region = m[:region],
        variant = m[:variant],
        extension = m[:extension],
        privateUse = m[:privateUseA] !== nothing ? m[:privateUseA] : m[:privateUseB],
    )
end

# Detect repeated variant subtags or repeated extension singletons within a
# well-formed langtag (case-insensitive). Mirrors hasDuplicateVariantOrSingleton
# in the TS reference; the regex alone can't enforce this.
function _has_duplicate_variant_or_singleton(input::AbstractString, m::RegexMatch)::Bool
    m[:grandfathered] !== nothing && return false
    m[:privateUseB] !== nothing && return false

    subtags = String.(split(input, "-"))
    i = 2  # julia is 1-indexed; subtags[1] is the language

    if length(subtags[1]) in (2, 3)
        # extlang: 0-3 subtags of 3 letters
        count = 0
        while count < 3 && i <= length(subtags) && occursin(r"\A[A-Za-z]{3}\z", subtags[i])
            i += 1
            count += 1
        end
    end

    # script
    if i <= length(subtags) && occursin(r"\A[A-Za-z]{4}\z", subtags[i]); i += 1; end
    # region
    if i <= length(subtags) && occursin(r"\A([A-Za-z]{2}|[0-9]{3})\z", subtags[i]); i += 1; end

    seen_variants = Set{String}()
    while i <= length(subtags) && occursin(r"\A([A-Za-z0-9]{5,8}|[0-9][A-Za-z0-9]{3})\z", subtags[i])
        key = lowercase(subtags[i])
        key in seen_variants && return true
        push!(seen_variants, key)
        i += 1
    end

    seen_singletons = Set{String}()
    while i <= length(subtags) && occursin(r"\A[0-9A-WYZa-wyz]\z", subtags[i])
        singleton = lowercase(subtags[i])
        singleton in seen_singletons && return true
        push!(seen_singletons, singleton)
        i += 1
        while i <= length(subtags) && occursin(r"\A[A-Za-z0-9]{2,8}\z", subtags[i])
            i += 1
        end
    end

    return false
end
