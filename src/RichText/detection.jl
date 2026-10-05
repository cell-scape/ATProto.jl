# Facet detection. Port of `packages/api/src/rich-text/{detection,util}.ts`
# regexes translated to PCRE. Facet indices are 0-based UTF-8 byte offsets
# (the atproto convention); Julia regex offsets are 1-based bytes.

const VALID_TLDS = Set(["ac", "academy", "accountant", "accountants", "active", "ad", "ae", "aero", "af", "ag", "agency", "ai", "airforce", "al", "am", "amsurance", "ao", "app", "apraisal", "ar", "archi", "army", "as", "asia", "associates", "at", "au", "auction", "audio", "auto", "aw", "ax", "az", "ba", "band", "bargains", "bb", "bd", "be", "beer", "bf", "bg", "bh", "bi", "bid", "bike", "bio", "biz", "bj", "black", "blue", "bm", "bn", "bo", "boutique", "br", "bs", "bt", "build", "builders", "business", "bw", "by", "bz", "ca", "cab", "cafe", "camera", "camp", "capital", "cards", "care", "careers", "cash", "casino", "cat", "cc", "cd", "center", "cf", "cg", "ch", "cheap", "church", "ci", "city", "ck", "cl", "claims", "cleaning", "clinic", "clothing", "club", "cm", "cn", "co", "coach", "codes", "coffee", "com", "community", "company", "computer", "condos", "construction", "consulting", "contractors", "cooking", "cool", "coop", "country", "cr", "credit", "cricket", "cruises", "cu", "cv", "cw", "cx", "cy", "cz", "dairy", "date", "dating", "de", "deals", "degree", "delivery", "dental", "dentist", "desi", "dev", "diamonds", "digital", "direct", "directory", "discount", "dj", "dk", "dm", "dnp", "do", "domains", "download", "dz", "earth", "ec", "edu", "education", "ee", "eg", "eh", "email", "energy", "engineer", "engineering", "enterprises", "equipment", "er", "es", "estate", "et", "events", "example", "exchange", "expert", "exposed", "express", "fail", "faith", "family", "fan", "farm", "fashion", "feedback", "fi", "finance", "fish", "fitness", "fj", "fk", "flights", "florist", "fm", "fo", "football", "forex", "forsale", "foundation", "fr", "fund", "furniture", "futbol", "ga", "gallery", "games", "garden", "gd", "ge", "gf", "gg", "gh", "gi", "gift", "gifts", "gives", "gl", "glass", "global", "gm", "gmbh", "gn", "gold", "golf", "gov", "gp", "gq", "gr", "graphics", "gratis", "gt", "gu", "guide", "guitars", "guru", "gy", "hangout", "haus", "healthcare", "help", "here", "hiphis", "hiv", "hk", "hm", "hn", "hockey", "holdings", "holiday", "hospital", "host", "hosting", "house", "how", "hr", "ht", "hu", "ice", "id", "ie", "il", "im", "immo", "immobilien", "in", "industries", "info", "ink", "institute", "insure", "int", "international", "invalid", "investments", "io", "iq", "ir", "irish", "is", "it", "java", "je", "jm", "jo", "job", "jobs", "jp", "juegos", "kaufen", "ke", "kg", "kh", "ki", "kim", "kitchen", "kiwi", "km", "kn", "kosher", "kr", "kw", "ky", "kz", "la", "land", "lawyer", "lb", "lc", "lease", "legal", "lens", "li", "lighting", "limited", "limo", "link", "live", "lk", "loan", "loans", "local", "localhost", "lol", "london", "lotto", "love", "lr", "ls", "lt", "lu", "luxe", "luxury", "lv", "ly", "ma", "maison", "management", "market", "marketing", "markets", "mba", "mc", "md", "me", "media", "meet", "memorial", "men", "menu", "mf", "mg", "mh", "miami", "mil", "mini", "mk", "ml", "mm", "mn", "mo", "mobi", "mod", "mom", "money", "mortgage", "moscow", "motor", "movie", "mq", "mr", "ms", "mt", "mu", "museum", "mv", "mw", "mx", "my", "mz", "na", "nagoya", "name", "navy", "nc", "ne", "net", "network", "neustar", "nf", "ng", "ni", "ninja", "nl", "no", "nokia", "now", "np", "nr", "nu", "nyc", "nz", "office", "om", "one", "onions", "online", "org", "organic", "pa", "paris", "parts", "party", "pe", "pet", "pf", "pg", "ph", "photo", "photography", "photos", "pictures", "pink", "pizza", "pk", "pl", "place", "plumbing", "plus", "pm", "poker", "porn", "post", "pr", "press", "pro", "produce", "prof", "promo", "properties", "ps", "pt", "pub", "pw", "py", "qa", "qpon", "racing", "re", "realty", "recipes", "red", "rehabreise", "rent", "repairs", "report", "republic", "restaurant", "review", "reviews", "rich", "ro", "rock", "rogers", "room", "rs", "rsvp", "ru", "ruhr", "run", "rw", "sa", "saar", "sale", "salon", "samsung", "sarl", "sb", "sc", "school", "schule", "science", "sd", "se", "search", "secure", "security", "services", "sex", "sexy", "sg", "sh", "shoes", "shop", "show", "si", "singe", "singles", "site", "sk", "sketch", "sl", "sm", "sn", "so", "soc", "soy", "space", "spiegel", "sr", "ss", "st", "studiostyle", "style", "sucks", "supplies", "supply", "support", "surf", "surgery", "sv", "sy", "systems", "tack", "taxi", "tc", "td", "team", "tech", "technology", "tel", "telefon", "temple", "tennis", "test", "tf", "tg", "th", "theater", "theatre", "tienda", "tips", "tires", "tirol", "tj", "tl", "tm", "tn", "to", "today", "tokyo", "tools", "top", "tours", "town", "toys", "tr", "trade", "trading", "training", "travel", "trust", "tt", "tui", "tv", "tw", "tz", "ua", "ug", "uk", "university", "us", "uy", "uz", "va", "vacations", "vc", "ve", "vegas", "venturesversicherung", "vet", "vg", "vi", "via", "videos", "ville", "vision", "vista", "vn", "vodka", "vote", "voting", "voyage", "vu", "wales", "watch", "webcams", "website", "wed", "wedding", "wf", "wien", "wiki", "wine", "work", "works", "world", "wow", "ws", "wtf", "xxx", "xyz", "yachts", "ye", "yoga", "yokohama", "za", "zm", "zone", "zw"])

const MENTION_REGEX = r"(^|\s|\()(@)([a-zA-Z0-9.-]+)(\b)"
const URL_REGEX = r"(^|\s|\()((https?://\S+)|((?<domain>[a-z][a-z0-9]*(\.[a-z0-9]+)+)\S*))"im
const TRAILING_PUNCTUATION_REGEX = r"\p{P}+$"
const TAG_REGEX = r"(^|\s)[#＃]((?!\ufe0f)[^\s\x{00AD}\x{2060}\x{200A}\x{200B}\x{200C}\x{200D}\x{20E2}]*[^\d\s\p{P}\x{00AD}\x{2060}\x{200A}\x{200B}\x{200C}\x{200D}\x{20E2}]+[^\s\x{00AD}\x{2060}\x{200A}\x{200B}\x{200C}\x{200D}\x{20E2}]*)?"
const CASHTAG_REGEX = r"(^|\s|\()\$([A-Za-z][A-Za-z0-9]{0,4})(?=\s|$|[.,;:!?)\"'\x{2019}])"

"A plausible domain suffix: dotted, valid handle-ish, or a .test domain."
function is_valid_domain_suffix(str::AbstractString)::Bool
    isempty(str) && return false
    # check the TLD against a known list (mirrors the TS reference's tlds pkg)
    last_dot = findlast('.', str)
    last_dot === nothing && return false
    tld = lowercase(str[nextind(str, last_dot):end])
    return tld in VALID_TLDS
end

"""
    detect_facets(text::UnicodeString; agent=nothing) -> Union{Vector{Dict}, Nothing}

Detect mentions (`@handle`), links (URLs and bare domains), tags (`#tag`),
and cashtags (`\$TICK`) in text. Returns facet dicts with 0-based UTF-8 byte
indices. When `agent` is given, mention handles are resolved to DIDs via
`com.atproto.identity.resolveHandle`.
"""
function detect_facets(text::UnicodeString;
                       agent = nothing)::Union{Vector{Dict{String,Any}},Nothing}
    facets = Dict{String,Any}[]

    # --- mentions: (^|\s|\()(@)(handle) — capture 3 is the handle ---------------
    for m in eachmatch(MENTION_REGEX, text.text)
        handle = m[3]
        handle === nothing && continue
        is_valid_domain_suffix(handle) || continue
        at_byte = m.offsets[3] - 1       # the '@' byte position (1-based)
        byte_start = at_byte - 1          # 0-based facet index
        byte_end = m.offsets[3] + ncodeunits(handle) - 1
        did = String(handle)
        if agent !== nothing
            try
                res = API.com.atproto.identity.resolve_handle(agent; handle = handle)
                d = get(res, "did", nothing)
                d isa AbstractString && (did = String(d))
            catch
                did = ""
            end
        end
        push!(facets, _facet(byte_start, byte_end,
            [Dict{String,Any}("\$type" => "app.bsky.richtext.facet#mention",
                              "did" => did)]))
    end

    # --- links: capture 2 is the URL text -----------------------------------------
    for m in eachmatch(URL_REGEX, text.text)
        matched = m[2]
        matched === nothing && continue
        uri = String(matched)
        if !startswith(uri, "http")
            domain = m[:domain]
            (domain === nothing || isempty(domain) ||
             !is_valid_domain_suffix(domain)) && continue
            uri = "https://" * uri
        end
        start_byte = m.offsets[2] - 1  # 0-based
        end_byte = start_byte + ncodeunits(matched)
        # strip trailing punctuation from the match (and the byte range)
        while occursin(r"[.,;:!?]$", uri)
            uri = uri[1:prevind(uri, ncodeunits(uri))]
            end_byte -= 1
        end
        if endswith(uri, ")") && !occursin("(", uri)
            uri = uri[1:prevind(uri, ncodeunits(uri))]
            end_byte -= 1
        end
        push!(facets, _facet(start_byte, end_byte,
            [Dict{String,Any}("\$type" => "app.bsky.richtext.facet#link",
                              "uri" => uri)]))
    end

    # --- tags: (^|\s)#tag — capture 1 is the leading boundary ---------------------
    for m in eachmatch(TAG_REGEX, text.text)
        lead_raw = m[1]
        local leading::String = lead_raw === nothing ? "" : String(lead_raw)
        tag = m[2]
        tag === nothing && continue
        tag = String(strip(tag))
        tag = replace(tag, r"\p{P}+$" => "")
        isempty(tag) && continue
        (length(tag) > 64 && grapheme_length(UnicodeString(tag)) > 64) && continue
        hash_byte = m.offset + ncodeunits(leading)  # the '#' byte (1-based)
        byte_start = hash_byte - 1
        byte_end = byte_start + 1 + ncodeunits(tag)
        push!(facets, _facet(byte_start, byte_end,
            [Dict{String,Any}("\$type" => "app.bsky.richtext.facet#tag",
                              "tag" => tag)]))
    end

    # --- cashtags: (^|\s|\()$TICK ---------------------------------------------------
    for m in eachmatch(CASHTAG_REGEX, text.text)
        lead_raw = m[1]
        local leading::String = lead_raw === nothing ? "" : String(lead_raw)
        tick_raw = m[2]
        tick_raw === nothing && continue
        ticker = uppercase(String(tick_raw))
        dollar_byte = m.offset + ncodeunits(leading)
        byte_start = dollar_byte - 1
        byte_end = byte_start + 1 + ncodeunits(ticker)
        push!(facets, _facet(byte_start, byte_end,
            [Dict{String,Any}("\$type" => "app.bsky.richtext.facet#tag",
                              "tag" => "\$" * ticker)]))
    end

    isempty(facets) && return nothing
    sort!(facets; by = f -> f["index"]["byteStart"])
    return facets
end

function _facet(byte_start::Int, byte_end::Int, features)::Dict{String,Any}
    return Dict{String,Any}(
        "\$type" => "app.bsky.richtext.facet",
        "index" => Dict{String,Any}("byteStart" => byte_start,
                                    "byteEnd" => byte_end),
        "features" => features,
    )
end
