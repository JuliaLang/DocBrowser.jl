# The manual: the Markdown pages that Julia's HTML documentation is built from, and the manual
# pages of the standard libraries.

# Where the Markdown source of the manual is: installed with Julia if it is, or downloaded.
manual_dir() = something(installed_manual_dir(), downloaded_manual_dir())

# Where the images of the manual page at `path` are. A downloaded manual has none, but the
# HTML manual installed with Julia has them, in the same places.
function image_dirs(path::String)
    dirs = [dirname(path)]
    dir = manual_dir()
    if startswith(path, dir) && dir != installed_manual_dir()
        push!(dirs, normpath(Sys.BINDIR, Base.DOCDIR, "html", "en", relpath(dirname(path), dir)))
    end
    return dirs
end

function installed_manual_dir()
    dir = normpath(Sys.BINDIR, Base.DOCDIR, "src")
    return isfile(joinpath(dir, "pages.toml")) ? dir : nothing
end

"""
    manual_pages(dir) -> Vector{ManualPage}

The pages of the manual, in the order that `pages.toml` gives. Pages that are listed but not
installed are left out.
"""
function manual_pages(dir::String=manual_dir())
    pages = ManualPage[]
    toml = joinpath(dir, "pages.toml")
    isfile(toml) || return pages
    d = @attempt Base.parsed_toml(toml) return pages
    for (key, role) in (("manual", :manual), ("base", :basedocs))
        for rel in get(d, key, String[])
            rel isa AbstractString && add_manual_page!(pages, joinpath(dir, as_string(rel)), role, "")
        end
    end
    # The standard libraries ship their manual pages with their source.
    stdlibs = ManualPage[]
    for name in readdir(Sys.STDLIB)
        name == "Pkg" && continue # it has a section of its own
        path = stdlib_page(name)
        path === nothing || add_manual_page!(stdlibs, path, :stdlibdocs, "")
    end
    solvers = joinpath(Sys.STDLIB, "SparseArrays", "docs", "src", "solvers.md")
    isfile(solvers) && add_manual_page!(stdlibs, solvers, :stdlibdocs, "")
    append!(pages, sort_by!(stdlibs, p -> lowercase(p.title)))
    for file in pkg_doc_files()::Vector{String}
        add_manual_page!(pages, joinpath(pkg_docs_dir(), file), :pkgdocs, "")
    end
    for g in get(d, "devdocs", Any[])
        g isa AbstractDict || continue
        for rel in get(g, "pages", String[])
            rel isa AbstractString && add_manual_page!(pages, joinpath(dir, as_string(rel)), :devdocs, as_string(get(g, "title", "")))
        end
    end
    return pages
end

# The manual page of a standard library, as the HTML manual picks it.
function stdlib_page(name::AbstractString)
    src = joinpath(Sys.STDLIB, name, "docs", "src")
    return isfile(joinpath(src, "index.md")) ? joinpath(src, "index.md") : nothing
end

pkg_docs_dir() = joinpath(Sys.STDLIB, "Pkg", "docs", "src")

# The pages of Pkg's manual, in the order that its documentation build lists them.
function pkg_doc_files()
    dir = pkg_docs_dir()
    isdir(dir) || return String[]
    make = joinpath(dir, "..", "make.jl")
    listed = isfile(make) ? String[String(m[1]::SubString{String}) for m in eachmatch(r"\"([\w-]+\.md)\"", read(make, String))] : String[]
    # Some pages are made by the build, so are not installed.
    files = filter(f -> isfile(joinpath(dir, f)), listed)
    isempty(files) || return files
    files = filter(f -> endswith(f, ".md") && f != "basedocs.md", readdir(dir))
    return sort_by!(files, f -> (f != "index.md", f))
end

## Links to places in the docs ##

# A place is written `docs: ` and then a page and a heading, as in
# `docs: manual/performance-tips#man-code-warntype` or `docs: stdlib/Pkg/environments`, or a
# name, as in `docs: Base.sum`. The address of the same place in the online docs works too.

"""
    place_target(text, cat) -> target or nothing

The place in the docs that `text` names, or `nothing` if it does not name one.
"""
function place_target(text::AbstractString, cat::Catalog)
    s = strip(text)
    t = pkgdocs_target(s)
    t === nothing || return t
    m = match(r"^https?://docs\.julialang\.org/en/[^/#]+/?([^#]*)(?:#(.*))?$", s)
    m === nothing && (m = match(r"^docs:\s*([^#]*?)\s*(?:#(.*))?$", s))
    m === nothing && return nothing
    ref, anchor = strip(m[1], '/'), String(strip(something(m[2], "")))
    path = place_file(ref)
    path === nothing && return isempty(anchor) ? name_place(ref, cat) : nothing
    # The online docs name the place of a docstring by its name, and then maybe its signature.
    if !isempty(anchor) && anchor_heading(cat, path, anchor) == 0
        t = name_place(first(split(anchor, '-')), cat)
        t === nothing || return t
    end
    return ManualTarget(path, anchor)
end

# The page that a place names, if it is installed.
function place_file(ref::AbstractString)
    parts = isempty(ref) ? ["index"] : split(ref, '/')
    any(p -> isempty(p) || p == "." || p == "..", parts) && return nothing
    path = if parts[1] == "stdlib" && length(parts) in (2, 3)
        joinpath(Sys.STDLIB, parts[2], "docs", "src", (length(parts) == 3 ? parts[3] : "index") * ".md")
    else
        joinpath(manual_dir(), parts...) * ".md"
    end
    return isfile(path) ? normpath(path) : nothing
end

function name_place(name::AbstractString, cat::Catalog)
    t = resolve_ref(name, Main, cat)
    t === nothing || return t isa URLTarget ? nothing : t
    # A name in a package that is not loaded yet, such as a stdlib in a new session: the
    # package is loaded, and then the name opened.
    name = String(strip(name))
    root = String(first(split(name, '.')))
    Base.isidentifier(root) || return nothing
    id = Base.identify_package(root)
    (id === nothing || haskey(Base.loaded_modules, id)) && return nothing
    return LoadTarget(id, name)
end

"""
    place_ref(cat, key, heading) -> String or nothing

What to write after `docs: ` to come back to `key`, at heading number `heading` of its page
(or its top for 0), or `nothing` if there is no way to.
"""
function place_ref(cat::Catalog, key, heading::Int)
    key isa NameEntry && return display_name(key)
    key isa ModuleTarget && return display_name(key.mod)
    key isa NameTarget && return string(display_name(key.mod), '.', key.name)
    key isa ManualTarget || return nothing
    ref = page_ref(key.path)
    ref === nothing && return nothing
    hs = page_headings(cat, key.path)
    heading in eachindex(hs) || return ref
    h = hs[heading]
    return string(ref, '#', isempty(h.id) ? slugify(h.text) : h.id)
end

# The page part of a place, from the file of a page.
function page_ref(path::String)
    path = normpath(path)
    rel = relpath(path, manual_dir())
    startswith(rel, "..") || return join(splitpath(splitext(rel)[1]), '/')
    parts = splitpath(splitext(relpath(path, normpath(Sys.STDLIB)))[1])
    length(parts) == 4 && parts[2] == "docs" && parts[3] == "src" || return nothing
    return string("stdlib/", parts[1], parts[4] == "index" ? "" : "/" * parts[4])
end

# A link to Pkg's online manual, as the page that is installed.
pkgdocs_target(url::AbstractString) = pkgdocs_target(String(url)::String)
function pkgdocs_target(url::String)
    m = match(r"^https?://pkgdocs\.julialang\.org/[^/#]+/?(?:([\w-]+)/?)?(?:#(.*))?$", url)
    m === nothing && return nothing
    path = normpath(pkg_docs_dir(), something(m[1], "index") * ".md")
    return isfile(path) ? ManualTarget(path, something(m[2], "")) : nothing
end

function add_manual_page!(pages::Vector{ManualPage}, path::String, role::Symbol, group::String)
    isfile(path) || return
    path = normpath(path) # so that it compares equal to the targets of links
    headings = scan_headings(path; limit=1)
    # A standard library's page goes by the library's name, which is what people look for.
    title = if role === :stdlibdocs && basename(path) != "solvers.md"
        stdlib_name(path)
    else
        isempty(headings) ? splitext(basename(path))[1] : headings[1].text
    end
    # Pkg numbers its chapters, which would skip the pages its build makes.
    role in (:pkgdocs, :package) && (title = replace(title, r"^(\*\*)?\d+\.(\*\*)?\s+" => ""))
    push!(pages, ManualPage(path, title, role, group))
end

const HEADING = r"^(#{1,6})\s+(.*?)\s*#*\s*$"
const ID_HEADING = r"^\[(.*)\]\(@id\s+([^)]+)\)$"

# The headings of a page, found quickly without parsing it, with their lines. This is close to
# what the page renders, and is used to search and to find pages; what a page shows comes from
# parsing it. With `limit`, stop after that many.
scan_headings(path::String; limit::Int=typemax(Int)) = open(io -> scan_headings(io, limit), path)

function scan_headings(io::IO, limit::Int)
    headings = Heading[]
    fence = ""
    prev = ""
    for (n, line) in enumerate(eachline(io))
        if !isempty(fence)
            # As in the Markdown parser, a fence closes with a line that starts with it exactly.
            startswith(line, fence) && !startswith(line, fence * fence[1]) && (fence = "")
            continue
        end
        m = match(r"^ {0,3}(```+|~~~+)(.*)$", line)
        # A backtick fence cannot have backticks after it, so that is inline code.
        if m !== nothing && !(startswith(m[1], '`') && occursin('`', m[2]))
            fence = m[1]
            prev = ""
            continue
        end
        m = match(HEADING, line)
        if m !== nothing
            push_heading!(headings, length(m[1]), m[2], n)
        elseif occursin(r"^(=+|-+)\s*$", line) && !isempty(strip(prev)) && !startswith(lstrip(prev), r"[-*+>|]")
            # an underlined heading
            push_heading!(headings, startswith(line, '=') ? 1 : 2, strip(prev), n - 1)
        end
        length(headings) >= limit && break
        prev = line
    end
    return headings
end

function push_heading!(headings::Vector{Heading}, level::Int, text::AbstractString, line::Int)
    id = ""
    idm = match(ID_HEADING, text)
    idm === nothing || ((text, id) = (idm[1], strip(idm[2])))
    # Headings are shown as plain text, without the Markdown of their links and code.
    text = replace(replace(text, r"\[([^\]]*)\]\([^)]*\)" => s"\1"), "`" => "", "**" => "", "__" => "")
    push!(headings, Heading(level, strip(text), id, line))
end

"""
    page_headings(cat, path) -> Vector{Heading}

The headings of a page as it is shown: those of its parsed Markdown, in order, without those
that have no letters or digits, which are not shown as headings. These line up with the
headings of the rendered page, which the names pane and links scroll to.
"""
function page_headings(cat::Catalog, path::String)
    get!(cat.headings, path) do
        isfile(path) || return Heading[]
        md = @attempt Markdown.parse(read(path, String)) return Heading[]
        headings = Heading[]
        walk_md(md) do x
            @nospecialize x # so that this is not compiled again for each level of heading
            x isa Markdown.Header || return
            text, id = x.text, ""
            link = id_link(x)
            if link !== nothing
                id = String(strip(chopprefix(link.url, "@id")))
                text = link.text
            end
            t = String(strip(replace(md_text(text)::String, r"\s+" => ' ')))
            any(c -> isletter(c) || isdigit(c), t) && push!(headings, Heading(heading_level(x), t, id, 0))
        end
        headings
    end
end

heading_level(::Markdown.Header{l}) where {l} = l

# The link that is the whole of a heading and gives it an `@id`, or `nothing`.
function id_link(@nospecialize(h::Markdown.Header))
    link = length(h.text) == 1 ? h.text[1] : nothing
    return link isa Markdown.Link && startswith(link.url, "@id") ? link : nothing
end

# The place among a page's shown headings of the heading with this text, or 0.
function heading_index(cat::Catalog, path::String, text::AbstractString)
    isempty(text) && return 0
    return something(findfirst(h -> h.text == text, page_headings(cat, path)), 0)
end

"""
    manual_anchors(cat) -> Dict{String,String}

The page of every heading of the manual, by its `@id`, its text and its slug: the names that
Documenter's `@ref` links use for a heading.
"""
function manual_anchors(cat::Catalog)
    cat.anchors === nothing || return cat.anchors
    anchors = Dict{String,String}()
    for p in cat.manual
        for h in scan_headings(p.path)
            isempty(h.id) || get!(anchors, h.id, p.path)
            get!(anchors, h.text, p.path)
            get!(anchors, slugify(h.text), p.path)
        end
    end
    cat.anchors = anchors
    return anchors
end

# How Documenter turns a heading into the name that `@ref` and `#` links use.
function slugify(s::AbstractString)
    s = replace(s, r"\s+" => "-", "&" => "-and-")
    s = replace(s, r"[^\p{L}\p{P}\d\-]+" => "")
    return String(strip(replace(s, r"\-\-+" => "-"), '-'))
end

# The heading of page `path` that `anchor` names, as a place among its headings, or 0 for the top.
function anchor_heading(cat::Catalog, path::String, anchor::String)
    isempty(anchor) && return 0
    for (k, h) in enumerate(page_headings(cat, path))
        (h.id == anchor || h.text == anchor || slugify(h.text) == anchor) && return k
    end
    return 0
end

# The place of the page in the manual. The sidebar asks for it for each row it draws.
function manual_page_of(cat::Catalog, path::String)
    pages, index = cat.manual_index
    if pages !== cat.manual
        index = Dict{String,Int}()
        for (i, p) in enumerate(cat.manual)
            get!(index, p.path, i)
        end
        cat.manual_index = (cat.manual, index)
    end
    return something(get(index, path, nothing), get(index, normpath(path), nothing), Some(nothing))
end

# The first page of a package's Documenter manual, which standard libraries and many packages
# ship with their source.
function package_manual(m::Module)
    dir = pkgdir(m)
    dir === nothing && return nothing
    in_stdlib_dir(dir) && return stdlib_page(basename(dir))
    path = joinpath(dir, "docs", "src", "index.md")
    return isfile(path) ? normpath(path) : nothing
end

# The module that names on a manual page are looked up in: the standard library it documents,
# or else `Main`.
function manual_context(path::String, cat::Union{Nothing,Catalog}=nothing)
    if !in_stdlib_dir(path)
        p = cat === nothing ? nothing : page_package(cat, path)
        return p === nothing ? Main : p.mod
    end
    name = stdlib_name(path)
    for m in Base.loaded_modules_array()
        id = PkgId(m)
        # a package can have the name of a standard library
        id.name == name && is_stdlib(id) && return m
    end
    return Main
end

# Links between manual pages point at their files, as only file and web links survive rendering.
const MANUAL_LINK = "file://"
manual_url(path::AbstractString, anchor::AbstractString="") = string(MANUAL_LINK, path, '#', anchor)

# The page and anchor of a link to a Markdown file, or `nothing`. The anchor follows the last
# `#`, as a path may have one too.
manual_target(url::AbstractString) = manual_target(as_string(url))
function manual_target(url::String)
    startswith(url, MANUAL_LINK) || return nothing
    s = chopprefix(url, MANUAL_LINK)
    endswith(s, ".md") && return ManualTarget(String(s), "")
    i = findlast('#', s)
    i === nothing && return nothing
    path = s[1:prevind(s, i)]
    return endswith(path, ".md") ? ManualTarget(String(path), String(s[nextind(s, i):end])) : nothing
end

is_manual_link(url::AbstractString) = manual_target(url) !== nothing

"""
    documenter!(md, path, ctx, cat) -> md

Turn the Documenter syntax of a manual page into plain Markdown that the browser can show:

  - `@docs` blocks become lists of the names they document, which are links;
  - `@example` and `@repl` blocks become Julia code, without their output;
  - blocks that only set up the build, such as `@meta`, `@setup` and `@eval`, are left out;
  - headings lose their `@id`, and `@ref` links to headings, and links to other pages, lead
    to those pages.
"""
function documenter!(md::Markdown.MD, path::String, ctx::Module, cat::Catalog)
    md.content = documenter_blocks(md.content, ctx, cat)
    walk_md(md) do x
        x isa Markdown.Link && (x.url = manual_link(x, path, ctx, cat))
    end
    return md
end

function documenter_blocks(blocks::Vector, ctx::Module=Main, cat::Union{Nothing,Catalog}=nothing)
    out = Any[]
    for x in blocks
        if x isa Markdown.Code && startswith(x.language, "@")
            # Options can follow the name, as in `@docs; canonical=false`.
            lang = first(split(x.language, (' ', ';')))
            if lang in ("@example", "@repl")
                push!(out, Markdown.Code("julia", x.code))
            elseif lang == "@autodocs" && cat !== nothing
                push_names!(out, autodocs_names(x.code, ctx, cat))
            elseif lang == "@docs"
                push_names!(out, split(x.code, '\n'))
            end
        elseif x isa Markdown.Header
            link = id_link(x)
            link === nothing || (x.text = link.text)
            push!(out, x)
        elseif x isa Markdown.Admonition
            x.content = documenter_blocks(x.content, ctx, cat)
            push!(out, x)
        else
            push!(out, x)
        end
    end
    return out
end

# The names as a list of code, which become links. Blank names are left out.
function push_names!(out::Vector{Any}, names)
    items = Any[]
    for n in names
        name = strip(n)
        isempty(name) || push!(items, Any[Markdown.Paragraph(Any[Markdown.Code(String(name))])])
    end
    isempty(items) || push!(out, Markdown.List(items, -1, false))
    return out
end

function manual_link(link::Markdown.Link, path::String, ctx::Module, cat::Catalog)
    url = link.url
    if startswith(url, "@ref")
        target = strip(strip(chopprefix(url, "@ref")), '"')
        key = String(isempty(target) ? strip(replace(md_text(link.text)::String, r"\s+" => ' ')) : target)
        # As in Documenter, a link written as code names a docstring, and one in words a heading.
        code = length(link.text) == 1 && link.text[1] isa Markdown.Code
        anchors = manual_anchors(cat)
        heading_page() = something(get(anchors, key, nothing), get(anchors, slugify(key), nothing), Some(nothing))
        page = code ? nothing : heading_page()
        page === nothing || return manual_url(page, key)
        resolve_ref(strip(key, '`'), ctx, cat) === nothing || return url
        # Code that names no docstring can still name a heading.
        page = code ? heading_page() : nothing
        page === nothing || return manual_url(page, key)
        return anchor_heading(cat, path, key) == 0 ? url : manual_url(path, key)
    end
    t = pkgdocs_target(url)
    t === nothing || return manual_url(t.path, t.anchor)
    occursin(r"^[a-z][a-z0-9+.-]*:"i, url) && return url
    file, anchor = occursin('#', url) ? split(url, '#'; limit=2) : (url, "")
    file = isempty(file) ? path : normpath(dirname(path), file)
    endswith(file, ".md") && isfile(file) || return url
    return manual_url(file, anchor)
end

"""
    manual_page(cat, path, width, pictures=nothing) -> Page

A manual page, with its Documenter syntax made plain, and its images drawn as pictures
where `pictures` says the terminal can.
"""
function manual_page(cat::Catalog, path::String, width::Int, pictures::Union{Nothing,PictureSupport}=nothing)
    pb = PageBuilder(width, pictures)
    addline!(pb)
    ctx = manual_context(path, cat)
    pkg = in_stdlib_dir(path) ? nothing : page_package(cat, path)
    if pkg !== nothing
        addline!(pb, "  ", ("the $(pkg.id.name) manual  ", :REPL_DocBrowser_dim),
                 ("↑ $(pkg.id.name)", nothing, ModuleTarget(pkg.mod)))
        addline!(pb)
        gap_notice!(pb, package_docs(cat, pkg.mod), online_docs(pkg.id, pkgdir(pkg.mod)))
    end
    # The page of a package that is not loaded: its docstrings, and links to its names, need
    # it to be.
    id = ctx === Main ? unloaded_owner(cat, path) : nothing
    if id !== nothing
        addline!(pb, "  ", ("$(id.name) is not loaded, so its docstrings, and links to its names, are not here.  ", :REPL_DocBrowser_dim),
                 (" Load $(id.name) ", :REPL_DocBrowser_link_active, LoadTarget(id)))
        addline!(pb)
    end
    source = startswith(path, manual_dir()) ? manual_source() : nothing
    if source !== nothing
        commit = first(julia_ref(), 10)
        from = startswith(source, "v") ? source : "the $source branch"
        addtext!(pb, "  ", "This Julia was built from $commit, which is not on GitHub, so this page is from $from.",
                 :REPL_DocBrowser_dim)
        addline!(pb)
    end
    md = Markdown.parse(read(path, String))
    documenter!(md, path, ctx, cat)
    add_markdown!(pb, md, ctx, cat; dirs=image_dirs(path))
    addline!(pb)
    return Page(pb, SourceTarget(path, 1))
end

## Searching the manual ##

# How well `q` matches `s`, both lowercase: the whole of it, its start, a word in it, or any part.
function match_score(q::AbstractString, s::AbstractString)
    s == q && return 300
    startswith(s, q) && return 200
    occursin(" " * q, s) && return 150
    return occursin(q, s) ? 100 : 0
end

# A page's short name: the standard library it documents, or else its file. Pkg's pages are
# named for Pkg too, so that searching for it finds them.
function page_name(p::ManualPage)
    p.role === :stdlibdocs && return stdlib_name(p.path)
    name = splitext(basename(p.path))[1]
    p.role === :pkgdocs || return name
    return name == "index" ? "Pkg" : "Pkg " * name
end

"""
    search_manual(cat, query; text=false) -> Vector{ManualHit}

The pages and headings of the manual that match `query`, best first. Pages come before
headings. With `text`, the words of each section are searched instead, as for docstrings.
"""
function search_manual(cat::Catalog, query::AbstractString; text::Bool=false, limit::Int=30)
    q = lowercase(strip(query))
    hits = ManualHit[]
    isempty(q) && return hits
    if text
        words = split(q)
        sections = manual_sections(cat)
        found = find_matches(i -> all(w -> occursin(w, sections[i][3]), words), cat.section_matches,
                             sections, join(words, ' '), words_narrow)
        for i in found
            path, heading, body = sections[i]
            score = sum(w -> count(w, body), words) + (occursin(q, body) ? 50 : 0)
            push!(hits, ManualHit(path, heading, score))
        end
    else
        for p in cat.manual
            # A match on the title counts for more than one on the file name.
            s = max(match_score(q, lowercase(p.title)), match_score(q, lowercase(page_name(p))) - 50)
            s > 0 && push!(hits, ManualHit(p.path, "", 1000 + s))
            for (k, h) in enumerate(index_headings(cat, p.path))
                k == 1 && h.level == 1 && continue # the title
                s = match_score(q, lowercase(h.text))
                s > 0 && push!(hits, ManualHit(p.path, h.text, s))
            end
        end
    end
    sort_by!(hits, h -> -h.score)
    length(hits) > limit && resize!(hits, limit)
    return hits
end

# The lowercased text of every section of the manual, with its page and heading.
function manual_sections(cat::Catalog)
    cat.sections === nothing || return cat.sections
    sections = Tuple{String,String,String}[]
    for p in cat.manual
        lines = readlines(p.path)
        hs = index_headings(cat, p.path)
        starts = pushfirst!(Int[h.line for h in hs], 1)
        for k in 0:length(hs)
            stop = k < length(hs) ? starts[k+2] - 1 : length(lines)
            body = lowercase(join(view(lines, starts[k+1]:stop), ' '))
            push!(sections, (p.path, k == 0 ? "" : hs[k].text, body))
        end
    end
    cat.sections = sections
    return sections
end

hit_title(cat::Catalog, h::ManualHit) = isempty(h.heading) ? manual_title(cat, h.path) : h.heading

# The heading a hit is at, among those its page shows.
hit_heading(cat::Catalog, h::ManualHit) = heading_index(cat, h.path, h.heading)

# The line of the file that a hit's heading is on.
function hit_line(cat::Catalog, h::ManualHit)
    hs = index_headings(cat, h.path)
    i = findfirst(x -> x.text == h.heading, hs)
    return i === nothing ? 1 : hs[i].line
end

# The scanned headings of a page, kept for searching.
index_headings(cat::Catalog, path::String) = get!(() -> scan_headings(path), cat.index_headings, path)

function manual_title(cat::Catalog, path::String)
    i = manual_page_of(cat, path)
    return i === nothing ? basename(path) : cat.manual[i].title
end
