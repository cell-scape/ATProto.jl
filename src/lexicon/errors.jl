# Lexicon errors. Port of the error classes in `packages/lexicon/src/types.ts`.

"""
    LexiconValidationError <: Exception

A value failed lexicon validation. `path` is the property path
(e.g. `"Record/text"`).
"""
struct LexiconValidationError <: Exception
    msg::String
end

Base.showerror(io::IO, err::LexiconValidationError) =
    print(io, "LexiconValidationError: ", err.msg)

"""
    InvalidLexiconError <: Exception

A lexicon document itself is malformed (bad structure, invalid NSID,
misplaced main definition, or unresolvable reference).
"""
struct InvalidLexiconError <: Exception
    msg::String
end

Base.showerror(io::IO, err::InvalidLexiconError) =
    print(io, "InvalidLexiconError: ", err.msg)

"""
    LexiconDefNotFoundError <: Exception

A lexicon definition reference could not be resolved.
"""
struct LexiconDefNotFoundError <: Exception
    msg::String
end

Base.showerror(io::IO, err::LexiconDefNotFoundError) =
    print(io, "LexiconDefNotFoundError: ", err.msg)
