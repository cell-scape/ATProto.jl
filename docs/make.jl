using Documenter
using ATProto

makedocs(
    sitename = "ATProto",
    format = Documenter.HTML(),
    modules = [ATProto]
)

# Documenter can also automatically deploy documentation to gh-pages.
# See "Hosting Documentation" and deploydocs() in the Documenter manual
# for more information.
#=deploydocs(
    repo = "<repository url>"
)=#
