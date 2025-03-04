#= syntax/nsid.jl =#

#=
Grammar:

alpha       = a-zA-z
number      = 0-9
delim       = "."
segment     = alpha *( alpha / number / "-" )
authority   = segment *( delim segment )
name        = alpha *( alpha )
nsid        = authority delim name
=#

const NSID_RX = r"^[a-zA-Z]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)+(\.[a-zA-Z]([a-zA-Z]{0,61}[a-zA-Z])?)$"

@kwdef struct NSID
    authority::String = ""
    name::String = ""

    NSID(authority, name) = new(authority, name)
    function NSID(nsid::String)
        _ = ensure_valid_nsid(nsid)
        segments = split(nsid, '.')
        authority = join(reverse(segments[1:end-1]), '.')
        name = last(segments)
        new(authority, name)
    end
end

nsid(n::NSID) = string(n.authority, ".", n.name)
authority(n::NSID) = n.authority
name(n::NSID) = n.name

valid_nsid_char(c::Char) = isletter(c) || isdigit(c) || c in ('.', '-')

function ensure_valid_nsid(nsid::String)::Nothing
    !all(valid_nsid_char, nsid) && error("Disallowed_characters in NSID (ASCII letters, digits, dashes, periods only)")
    length(nsid) > 317 && error("NSID is too long (317 characters max)")

    labels = split(nsid, '.')
    length(labels) < 3 && error("NSID needs at least three parts")
    (first(labels) |> first |> isdigit) && error("NSID first part may not start with a digit")
    !all(isletter, last(labels)) && error("NSID name part must be only letters")

    for label in labels
        isempty(label) && error("NSID parts cannot be empty")
        length(label) > 63 && error("NSID part too long (63 chars max)")
        (startswith(label, '-') || endswith(label, '-')) && error("NSID parts can not start or end with hyphen")
    end

    return nothing
end

function is_valid_nsid(nsid::String)::Bool
    !all(valid_nsid_char, nsid) && return false
    length(nsid) > 317 && return false

    labels = split(nsid, '.')
    length(labels) < 3 && return false
    (first(labels) |> first |> isdigit) && return false
    !all(isletter, last(labels)) && return false

    for label in labels
        isempty(label) && return false
        length(label) > 63 && return false
        (startswith(label, '-') || endswith(label, '-')) && return false
    end

    return true
end

function ensure_valid_nsid_regex(nsid::String; pattern=NSID_RX)::Nothing
    isnothing(match(pattern, nsid)) && error("NSID didn't validate via regex")
    length(nsid) > 317 && error("NSID is too long (317 characters max)")
    return nothing
end

function is_valid_nsid_regex(nsid::String; pattern=NSID_RX)::Bool
    isnothing(match(pattern, nsid)) && return false
    length(nsid) > 317 && return false
    return true
end