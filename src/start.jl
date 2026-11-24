# The start page: where the browser opens in a fresh session.

# The sections of the start page, in order. The names pane lists them.
const START_SECTIONS = ("New to Julia?", "Finding things", "Your project", "Release notes")

# The systems that a tip can be for, by the names the tips file has for them.
const SYSTEMS = Dict("bsd" => Sys.isbsd, "linux" => Sys.islinux, "windows" => Sys.iswindows)

# The tips for the start page, as text with code in backticks and the section of the docs that
# says more: a standard library's name or `:manual`, a page and a heading, or nothing. They are
# read when the package is precompiled.
function read_tips(path::String)
    tips = Tuple{String,Union{Nothing,Tuple{Union{Symbol,String},String,String}}}[]
    for t in Base.parsed_toml(path)["tip"]
        os = get(t, "os", String[])
        os isa AbstractVector || continue
        isempty(os) || dynamic(any)(s -> SYSTEMS[s](), os)::Bool || continue
        VERSION >= VersionNumber(as_string(get(t, "julia", "1"))) || continue
        docs = get(t, "docs", nothing)
        link = docs === nothing ? nothing : (docs == "manual" ? :manual : docs, t["page"], t["heading"])
        push!(tips, (replace(strip(t["text"]), r"\s*\n\s*" => " "), link))
    end
    return tips
end

# The path is not kept: the package may be installed somewhere else from where it was built.
const TIPS = let path = joinpath(@__DIR__, "tips.toml")
    include_dependency(path)
    read_tips(path)
end

# A new order of the tips for each browser. It leaves the global random numbers alone, so that
# opening the browser does not change what `rand` gives afterwards.
tip_order() = (seed = time_ns() % UInt; sortperm([hash(i, seed) for i in eachindex(TIPS)]))

# The page that a tip links to, if it is installed.
function tip_link(tip)
    link = tip[2]
    link === nothing && return nothing
    path = link[1] === :manual ? joinpath(manual_dir(), "manual", link[2]) :
        joinpath(Sys.STDLIB, link[1], "docs", "src", link[2])
    return isfile(path) ? ManualTarget(path, link[3]) : nothing
end

# The words of a tip as segments, so that the paragraph can wrap between words, of code too.
function tip_segments(text::String)
    segs = Any[]
    for (i, part) in enumerate(split(text, '`'))
        if iseven(i)
            words = split(part, ' ')
            for (j, w) in enumerate(words)
                push!(segs, Any[(w, :markdown_code), j < length(words) ? " " : ""])
            end
        else
            words = [m.match for m in eachmatch(r"\S+\s*", part)]
            # What follows code stays on its line: a space, so that no line starts with one,
            # or punctuation.
            if !isempty(segs)
                push!(segs[end], startswith(part, ' ') ? " " : isempty(words) ? "" : popfirst!(words))
            end
            append!(segs, words)
        end
    end
    return segs
end

# Chapters of the manual to read first, by file.
const FIRST_CHAPTERS = ("getting-started", "variables", "functions", "control-flow", "types",
                        "methods", "modules", "arrays", "performance-tips", "workflow-tips")

const START_KEYS = (("/", "search names, the manual and the text of docstrings"),
                    ("^T", "search only names, or only text"),
                    ("click", "anything to open it; right-click opens its source"),
                    ("?", "every key, and what the marks mean"))

version_string() = string(@static isdefined(Base, :version_with_build_variant) ? Base.version_with_build_variant() : VERSION)

"""
    version_block!(pb, logo=nothing)

The version of Julia and what kind of build it is, beside the Julia logo. The logo is the
picture `logo` where the terminal has it, and three dots otherwise.
"""
function version_block!(pb::PageBuilder, logo::Union{Nothing,Picture}=nothing)
    git = Base.GIT_VERSION_INFO
    kind = isempty(VERSION.prerelease) ? "release" :
        "DEV" in VERSION.prerelease ? "development build" : "prerelease"
    date = isempty(git.date_string) ? "" : string(", ", first(split(git.date_string)))
    julia = ("Julia ", :REPL_DocBrowser_pane_title)
    version = (version_string(), :REPL_DocBrowser_title)
    build = (kind * date, :REPL_DocBrowser_dim)
    if logo !== nothing
        push!(pb.images, PageImage(length(pb.lines) + 1, 3, logo))
        addline!(pb)
        addline!(pb, " "^14, julia, version)
        addline!(pb, " "^14, build)
        addline!(pb)
        return pb
    end
    addline!(pb, "   ", ("●", :REPL_DocBrowser_logo_green), "    ", julia, version)
    addline!(pb, "  ", ("●", :REPL_DocBrowser_logo_red), " ", ("●", :REPL_DocBrowser_logo_purple), "   ", build)
end

# The release notes of this version of Julia: installed with the manual, or in the source tree.
function release_notes()
    for path in (joinpath(manual_dir(), "NEWS.md"), normpath(Sys.BINDIR, "..", "..", "NEWS.md"))
        isfile(path) && return ManualTarget(path, "")
    end
    return URLTarget(julia_docs("NEWS/"))
end

"""
    start_page(cat, width, tip=1, pos=tip, logo=nothing) -> Page

The start page: this Julia, and where to begin, how to find things, the packages of the
active project, the release notes, and tip number `tip`, shown as the `pos`th. `logo` is the
picture of the Julia logo, where the terminal has it.
"""
function start_page(cat::Catalog, width::Int, tip::Int=1, pos::Int=tip, logo::Union{Nothing,Picture}=nothing)
    pb = PageBuilder(width)
    addline!(pb)
    version_block!(pb, logo)

    section!(pb, START_SECTIONS[1])
    chapters = ManualPage[]
    for name in FIRST_CHAPTERS
        i = findfirst(p -> p.role === :manual && splitext(basename(p.path))[1] == name, cat.manual)
        i === nothing || push!(chapters, cat.manual[i])
    end
    if isempty(chapters)
        addflow!(pb, "  ", Any[("The manual is at ", nothing), (link_label(julia_docs()), nothing, URLTarget(julia_docs()))])
    else
        addline!(pb, "  ", "Start with ", (chapters[1].title, nothing, ManualTarget(chapters[1].path, "")),
                 ", then read on:")
        segs = Any[]
        for p in chapters[2:end]
            isempty(segs) || push!(segs, ("  ", nothing))
            push!(segs, (p.title, nothing, ManualTarget(p.path, "")))
        end
        addflow!(pb, "    ", segs)
    end

    section!(pb, START_SECTIONS[2])
    for (key, what) in START_KEYS
        addline!(pb, "    ", (rpad(key, 7), :REPL_DocBrowser_key), what)
    end

    section!(pb, START_SECTIONS[3])
    proj = Base.active_project()
    label = project_label()
    label === nothing || addline!(pb, "  ", (label, :REPL_DocBrowser_pane_title))
    proj === nothing || addline!(pb, "  ", (Base.contractuser(proj), :REPL_DocBrowser_dim))
    segs = Any[]
    for p in cat.pkgs
        p.role in (:project, :direct) || continue
        isempty(segs) || push!(segs, ("   ", nothing))
        version = p.version === nothing ? "" : string(" ", p.version)
        push!(segs, Any[(p.id.name, nothing, ModuleTarget(p.mod)), (version, :REPL_DocBrowser_dim)])
    end
    for id in cat.unloaded
        isempty(segs) || push!(segs, ("   ", nothing))
        push!(segs, Any[(id.name * " ", nothing), ("↓ load", :REPL_DocBrowser_key, LoadTarget(id))])
    end
    isempty(segs) ? addline!(pb, "  ", ("Nothing is loaded from it yet.", :REPL_DocBrowser_dim)) : addflow!(pb, "    ", segs)

    section!(pb, START_SECTIONS[4])
    notes = release_notes()
    addline!(pb, "  ", "What is new in Julia $(VERSION.major).$(VERSION.minor): ",
             (notes isa ManualTarget ? "NEWS.md" : link_label(notes.url), nothing, notes))
    addline!(pb)
    addline!(pb)
    tip_box!(pb, tip, pos)
    return Page(pb)
end

# A tip in a box of its own, so that it stands out from the rest of the page.
function tip_box!(pb::PageBuilder, tip::Int, pos::Int)
    t = TIPS[mod1(tip, length(TIPS))]
    # The box widens with the page, but leaves room beside it on a wide one.
    w = min(pb.width - 4, max(80, 4 * pb.width ÷ 5), 110)
    iw = w - 6
    # The box is as tall as the longest tip needs, so that it keeps its size from tip to tip.
    nlines(segs) = length(addflow!(PageBuilder(iw), "", segs).lines)
    text_rows = maximum(x -> nlines(tip_segments(x[1])), TIPS)
    control_rows = maximum(x -> nlines(tip_controls(x, length(TIPS))), TIPS)
    inner = PageBuilder(iw)
    addline!(inner)
    addflow!(inner, "", tip_segments(t[1]))
    while length(inner.lines) < 1 + text_rows
        addline!(inner)
    end
    addline!(inner)
    addflow!(inner, "", tip_controls(t, pos))
    while length(inner.lines) < 2 + text_rows + control_rows
        addline!(inner)
    end
    addline!(inner)
    label = " Did you know? "
    addline!(pb, "  ", ("╭─", :REPL_DocBrowser_tip), (label, :REPL_DocBrowser_tip_title),
             ("─"^max(0, w - 3 - textwidth(label)) * "╮", :REPL_DocBrowser_tip))
    for (k, line) in enumerate(inner.lines)
        row = length(pb.lines) + 1
        pad = " "^max(0, w - 6 - textwidth(String(line)))
        push!(pb.lines, concat("  ", styled("│  ", :REPL_DocBrowser_tip), line, pad,
                                        styled("  │", :REPL_DocBrowser_tip)))
        for s in inner.spots
            s.line == k && push!(pb.spots, Spot(row, s.cols .+ 5, s.target))
        end
    end
    addline!(pb, "  ", ("╰" * "─"^(w - 2) * "╯", :REPL_DocBrowser_tip))
end

# The links under a tip, and which of the tips it is.
function tip_controls(t, pos::Int)
    segs = Any[Any[("◂ previous", nothing, ToggleTarget(:tip_back)), "   "],
               Any[("next ▸", nothing, ToggleTarget(:tip)), "   "],
               Any[(string(mod1(pos, length(TIPS)), " of ", length(TIPS)), :REPL_DocBrowser_dim), "     "]]
    link = tip_link(t)
    link === nothing || push!(segs, ("more about this", nothing, link))
    return segs
end

# A section of the start page, as a heading that `{ }`, the names pane and links can find.
function section!(pb::PageBuilder, title::String)
    addline!(pb)
    addline!(pb, "  ", (title, :markdown_h2))
    addline!(pb, "  ", ("─"^textwidth(title), :markdown_h2))
end
