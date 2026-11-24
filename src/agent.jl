## Plain text, for programs and AI agents ##

# The pages are built by a browser that is never shown.
const HEADLESS = Ref{Any}(nothing)
# Whether the command line is running, which changes how the text says to do something.
const CLI = Ref(false)
# Why Julia's manual is missing, if it could not be downloaded.
const MANUAL_NOTE = Ref{Union{Nothing,String}}(nothing)
# Whether the last answer found what was asked for, which the command line's exit code says.
const FOUND = Ref(true)

function headless_browser()
    b = HEADLESS[]
    b isa Browser && return b
    ensure_manual()
    out = IOContext(IOBuffer(), :displaysize => (40, 120), :color => false)
    b = Browser(REPL.Terminals.TTYTerminal("", IOBuffer(), out, IOBuffer()))
    HEADLESS[] = b
    return b
end

# The manual is downloaded the first time it is needed, as the browser does when it first opens.
function ensure_manual()
    installed_manual_dir() === nothing || return
    isfile(joinpath(downloaded_manual_dir(), "pages.toml")) && return
    Base.generating_output() && return
    dynamic(println)(stderr, "Downloading Julia's manual for this version of Julia, which is done once...")
    try
        dynamic(download_manual)()
    catch err
        err isa InterruptException && rethrow()
        MANUAL_NOTE[] = "Julia's manual is not available, as it could not be downloaded: " * first_line(err)
    end
    return
end

load_hint() = CLI[] ? "run this again with `--load`" : "call this again with `load=true`"
search_hint() = CLI[] ? "search for it with `jldocs find`" : "search for it with `DocBrowser.find_docs`"

"""
    DocBrowser.lookup(query; outline=false, section=0, width=100, context=Main, load=false) -> String

The page that the browser shows for `query`, as plain text. `query` is a name such as
`Base.sort!` or `Plots.plot`, a place in a manual such as `manual/arrays#Broadcasting`,
`stdlib/Random` or the path of a Markdown file, or anything that `docs: ` takes at the
`help?>` prompt.

Links in the text end in a number, as in `sort[3]`, and the list at the end gives what each
links to, in a form that `lookup` takes. With `outline`, only the headings of the page are
listed, numbered; `section` gives the text under one of them.

A package of the active project that is not loaded stays unloaded, and its page shows what its
source documents, such as its README. With `load`, it is loaded first, which runs its code,
and then its docstrings can be read.
"""
function lookup(query::AbstractString; outline::Bool=false, section::Int=0, brief::Bool=false,
                width::Int=100, context::Module=Main, load::Bool=false)
    FOUND[] = true
    b = headless_browser()
    strip(query) in ("manual", "docs") && return manual_index(b)
    place = package_place(b, String(query))
    place isa PackageManual && return package_manual_index(place)
    t = something(place, agent_target(b.cat, String(query), context), Some(nothing))
    if t === nothing
        # The name can be one that a package of the project exports.
        if load && !isempty(b.cat.unloaded)
            load_project_packages(b)
            return invokelatest(lookup, query; outline, section, brief, width, context)
        end
        FOUND[] = false
        note = MANUAL_NOTE[] === nothing ? "" : "\n" * MANUAL_NOTE[]
        return "Nothing is called $(repr(query)); $(search_hint()).$note\n" * unloaded_note(b.cat)
    end
    t isa URLTarget && return "$(query) is a web page: $(t.url)\n"
    if t isa LoadTarget && load
        Core.eval(Main, :(import $(Symbol(t.id.name))))
        HEADLESS[] = nothing # the catalog was made before the package was loaded
        return invokelatest(lookup, query; outline, section, brief, width, context)
    end
    key, k = page_key(b.cat, t)
    key === nothing && (FOUND[] = false; return "There is no page for $(repr(query)).\n")
    push!(dynamic(get!)(Set{Symbol}, b.flags, key)::Set{Symbol}, :extended)
    p = page(b, key, width)
    io = IOBuffer()
    # the address of the page, without the file that a link to it is given with
    title = something(place_ref(b.cat, key, 0), link_ref(b, key, key), key_title(b, key))
    title = String(first(split(as_string(title), "  ")))
    v = page_version(key)
    pkgpage = key isa ManualTarget ? package_page(b, key.path) : nothing
    pkgpage === nothing || pkgpage[1].version === nothing || (v = "$(pkgpage[1].name) $(pkgpage[1].version)")
    println(io, "# ", title, v === nothing ? "" : "  ($v)")
    path = page_path(key, p)
    path === nothing || println(io, "Path: ", path)
    key isa LoadTarget && println(io, "(", key.id.name, " is not loaded, so its docstrings cannot be read. ",
                                  "To load it, which runs its code, ", load_hint(), ".)")
    # A package's manual, whose pages are listed in the browser with its names.
    name = key isa ModuleTarget && parentmodule(key.mod) === key.mod ? String(nameof(key.mod)) :
           key isa LoadTarget && isempty(key.then) ? key.id.name : nothing
    manual = name === nothing ? nothing : findfirst(m -> m.name == name, package_manuals(b))
    manual === nothing || println(io, "(Its manual has $(length(package_manuals(b)[manual].pages)) pages: ",
                                  CLI[] ? "`jldocs show $name/`" : "`lookup(\"$name/\")`", " lists them.)")
    if outline
        for (i, li) in enumerate(p.headings)
            from = docstring_from(p, li)
            println(io, "§", i, " ", strip(String(p.lines[li])), from === nothing ? "" : "  (from $from)")
        end
        isempty(p.headings) && println(io, "(this page has no headings)")
        if manual !== nothing
            m = package_manuals(b)[manual]
            println(io, "\nIts manual:")
            foreach((pg, ref) -> println(io, "  ", ref, "  ", pg.title), m.pages, m.refs)
        end
        return String(take!(io))
    end
    section == 0 && (section = k)
    section == 0 || section in eachindex(p.headings) || (FOUND[] = false; return "This page has no section $section.\n")
    part = section == 0 ? eachindex(p.lines) :
        (p.headings[section]:(section < length(p.headings) ? p.headings[section+1] - 1 : length(p.lines)))
    total = length(part)
    lines = filter(li -> !is_button_line(p, li), brief ? brief_lines(p, collect(part)) : collect(part))
    refs, numbers = link_numbers(b, key, p, lines)
    for li in lines
        text = String(p.lines[li])
        # the place in the margin of a block of code that copies it is not part of the text
        spots = [s for s in p.spots if s.line == li && !(s.target isa CodeTarget)]
        # A source location shows only its file's name, or its path from `~`, which a program
        # cannot always open.
        for s in spots
            s.target isa SourceTarget || continue
            full = string(s.target.file, ':', s.target.line)
            occursin(full, text) && continue
            short = string(contractuser(s.target.file), ':', s.target.line)
            text = replace(text, (occursin(short, text) ? short : string(basename(s.target.file), ':', s.target.line)) => full)
        end
        marks = Tuple{Int,String}[(mark_col(p.lines[li], s.cols), "[$(numbers[i])]") for (i, s) in enumerate(p.spots)
                                  if s.line == li && haskey(numbers, i)]
        # on a line of code, the marks go at its end, away from the code
        code = is_code_line(p.lines[li]) && !isempty(marks)
        line = code ? rstrip(text) * "  " * join(last.(sort!(marks)), "") : insert_marks(text, marks)
        println(io, rstrip(line))
    end
    brief && length(lines) < total && println(io, "\n(", total - length(lines), " more lines: drop `--brief`",
                                              " for all of it, or read one part with `--outline` and `--section`)")
    if !isempty(refs)
        println(io, "\nLinks:")
        for (n, ref) in enumerate(refs)
            println(io, "[", n, "] ", ref)
        end
    end
    return String(take!(io))
end

# The file that a page is read from, as a path a program can open: the Markdown of a page of a
# manual, the source of a docstring, or the directory of a package.
function page_path(@nospecialize(key), p::Page)
    key isa ManualTarget && return key.path
    key isa NameEntry && return p.source === nothing ? nothing : string(p.source.file, ':', p.source.line)
    key isa ModuleTarget && return something(pkgdir(key.mod), Some(nothing))
    key isa LoadTarget && return unloaded_dir(key.id)
    return nothing
end

# Whether line `li` only has buttons, such as the one that loads a package, which mean nothing
# in text. A button may have its key beside it.
function is_button_line(p::Page, li::Int)
    spots = [s for s in p.spots if s.line == li && !(s.target isa CodeTarget)]
    isempty(spots) && return false
    all(s -> s.target isa ToggleTarget || s.target isa LoadTarget, spots) || return false
    return textwidth(strip(String(p.lines[li]))) - sum(s -> length(s.cols), spots) <= 12
end

# The version of what a page documents: Julia's, or the package's.
function page_version(@nospecialize(key))
    m = key isa NameEntry ? key.mod : key isa ModuleTarget ? key.mod : nothing
    if key isa LoadTarget
        file = dynamic(Base.locate_package)(key.id)::Union{Nothing,String}
        file === nothing && return nothing
        proj = Base.current_project(dirname(dirname(file)))
        v = proj === nothing ? nothing : get(Base.parsed_toml(proj), "version", nothing)
        return v isa String ? "$(key.id.name) $v" : nothing
    end
    key isa ManualTarget && return startswith(key.path, manual_dir()) ? "Julia $VERSION" : nothing
    m === nothing && return nothing
    root = Base.moduleroot(m)
    root === Main && return nothing
    (root in (Base, Core) || is_stdlib(PkgId(root))) && return "Julia $VERSION"
    v = pkgversion(root)
    return v === nothing ? nothing : "$(nameof(root)) $v"
end

# The module that the docstring around line `li` comes from, when the page has the docstrings
# of several modules, which it labels.
function docstring_from(p::Page, li::Int)
    for k in li:-1:1
        m = match(r"^\s*From (\S+):$", String(p.lines[k]))
        m === nothing || return m[1]
    end
    return nothing
end

# The start of each docstring among `lines`: its signature and its first paragraph.
function brief_lines(p::Page, lines::Vector{Int})
    keep = Int[]
    # the header of a page ends with a rule; each docstring after it starts a part
    rule = findfirst(li -> occursin(r"^\s*─{8,}\s*$", String(p.lines[li])), lines)
    rule === nothing || append!(keep, lines[1:rule])
    taking, prose, contents = true, false, false
    for li in lines[something(rule, 0)+1:end]
        text = String(p.lines[li])
        blank = isempty(strip(text))
        # the list of contents, which can take more than one line, is not a paragraph
        startswith(lstrip(text), "Contents ") && (contents = true)
        blank && (contents = false)
        # each docstring after the first starts after a label of its module, or a rule
        if occursin(r"^\s*From (\S+):$", text) || occursin(r"^\s*─{8,}\s*$", text)
            taking, prose = true, false
            # the blank line that sets it apart from the docstring before
            li - 1 in lines && !(li - 1 in keep) && isempty(strip(String(p.lines[li-1]))) && push!(keep, li - 1)
        elseif taking && blank && prose
            taking = false
        elseif taking && !blank && !contents && !is_code_line(p.lines[li]) &&
               !(li in p.headings) && !occursin(r"^\s*[≡=\-]{3,}\s*$", text)
            # the first paragraph of text, not a heading or the line under one
            prose = true
        end
        taking && push!(keep, li)
    end
    return keep
end

# The pages of Julia's manual, by part, each with what `lookup` takes for it.
function manual_index(b::Browser)
    io = IOBuffer()
    println(io, "# Julia's manual  (Julia $VERSION)")
    isempty(b.cat.manual) && MANUAL_NOTE[] !== nothing && println(io, MANUAL_NOTE[])
    part = nothing
    for pg in b.cat.manual
        title = pg.role === :devdocs && !isempty(pg.group) ? pg.group : getfield(SIDEBAR_TITLES, pg.role)
        if title != part
            part = title
            println(io, "\n", title)
        end
        println(io, "  ", something(page_ref(pg.path), pg.path), "  ", pg.title)
    end
    return String(take!(io))
end

# The manual of a package, read from its source or downloaded, with the address of each page:
# the package's name, then the page's path under the directory of the manual's pages without
# `.md`, as in `GLMakie/explanations/backends/glmakie`.
struct PackageManual
    name::String
    version::Union{Nothing,String}
    pages::Vector{ManualPage}
    refs::Vector{String}
end

# The manuals of the packages the browser lists, loaded and not, that have one. Every link to a
# page of a manual asks, so they are found once for each browser.
const PACKAGE_MANUALS = Ref{Any}(nothing)
function package_manuals(b::Browser)
    c = PACKAGE_MANUALS[]
    c isa Tuple && c[1] === b && return c[2]::Vector{PackageManual}
    out = find_package_manuals(b)
    PACKAGE_MANUALS[] = (b, out)
    return out
end

function find_package_manuals(b::Browser)
    out = PackageManual[]
    seen = Set{String}()
    add(name, dir, docs) = begin
        (dir === nothing || isempty(docs.pages) || name in seen) && return
        push!(seen, name)
        root = common_dir(String[pg.path for pg in docs.pages])
        refs = [string(name, '/', replace(chopsuffix(relpath(pg.path, root), ".md"), '\\' => '/')) for pg in docs.pages]
        v = installed_version(dir)
        push!(out, PackageManual(name, v isa String ? v : nothing, docs.pages, refs))
    end
    # a standard library's manual is part of Julia's, at `stdlib/…`
    for p in b.cat.pkgs
        p.role in (:project, :direct, :indirect) && !is_stdlib(p.id) || continue
        add(p.id.name, pkgdir(p.mod), package_docs(b.cat, p.mod))
    end
    for id in b.cat.unloaded
        is_stdlib(id) || add(id.name, unloaded_dir(id), unloaded_docs(b.cat, id))
    end
    return out
end

installed_version(dir::String) = get(Base.parsed_toml(joinpath(dir, "Project.toml")), "version", nothing)

# The directory that all of `paths` are in.
function common_dir(paths::Vector{String})
    root = dirname(paths[1])
    for p in paths
        while !startswith(p, root * Base.Filesystem.path_separator) && dirname(root) != root
            root = dirname(root)
        end
    end
    return root
end

# What an address in a package's manual names: its page, at a heading after `#`, or the whole
# manual for `GLMakie/` or `GLMakie/manual`. `nothing` when it is not one.
function package_place(b::Browser, query::String)
    m = match(r"^([A-Za-z_]\w*)/([^#]*?)(?:#(.*))?$", strip(query))
    m === nothing && return nothing
    name, page, anchor = String(m[1]), chopsuffix(strip(String(m[2]), '/'), ".md"), something(m[3], "")
    i = findfirst(pm -> pm.name == name, package_manuals(b))
    i === nothing && return nothing
    pm = package_manuals(b)[i]
    page in ("", "manual") && return pm
    j = findfirst(==("$name/$page"), pm.refs)
    return j === nothing ? nothing : ManualTarget(pm.pages[j].path, String(anchor))
end

# The package manual a page belongs to, and the page's address, or `nothing`.
function package_page(b::Browser, path::String)
    for m in package_manuals(b)
        i = findfirst(pg -> pg.path == path, m.pages)
        i === nothing || return m, m.refs[i]
    end
    return nothing
end

# The pages of a package's manual, each with what `lookup` takes for it.
function package_manual_index(m::PackageManual)
    io = IOBuffer()
    println(io, "# The manual of ", m.name, m.version === nothing ? "" : "  ($(m.name) $(m.version))")
    group = nothing
    for (pg, ref) in zip(m.pages, m.refs)
        if pg.group != group
            group = pg.group
            isempty(group) || println(io, "\n", group)
        end
        println(io, "  ", ref, "  ", pg.title, "  ", pg.path)
    end
    return String(take!(io))
end

"""
    DocBrowser.find_docs(query; text=false, internal=false, limit=20, load=false) -> String

Names, and sections of Julia's manual and of the manuals of the project's packages, that match
`query`, best first, one a line, each in a form that [`lookup`](@ref) takes, and for a section
of a manual, its file. With `text`, the words are looked for in docstrings and in the text of
the manuals too, not only in names and headings; that is done anyway when nothing else matches.

The names of packages that are not loaded are not known until they are, which `load` does,
running their code. Their manuals are searched either way.
"""
function find_docs(query::AbstractString; text::Bool=false, internal::Bool=false, limit::Int=20, load::Bool=false)
    FOUND[] = true
    b = headless_browser()
    if load && !isempty(b.cat.unloaded)
        load_project_packages(b)
        return invokelatest(find_docs, query; text, internal, limit)
    end
    io = IOBuffer()
    names = search(b.cat, query; internal, limit)
    text && (names = unique!(vcat(names, search_text(b.cat, query; internal, limit))))
    for e in first(names, limit)
        print(io, display_name(e), "  ", e.kind, ", ", e.vis)
        from = reexported_from(e)
        from === nothing || print(io, ", from ", display_name(from))
        e.documented || print(io, ", undocumented")
        println(io)
    end
    for h in first(search_manual(b.cat, query; text), limit)
        ref = something(page_ref(h.path), h.path)
        isempty(h.heading) || (ref *= "#" * slugify(h.heading))
        # and the file, which can be read directly, unless that is what `show` takes
        println(io, ref, "  manual: ", hit_title(b.cat, h), startswith(ref, h.path) ? "" : "  " * h.path)
    end
    for (ref, name, title, path) in first(search_package_manuals(b, query; text), limit)
        println(io, ref, "  manual of ", name, ": ", title, "  ", path)
    end
    out = String(take!(io))
    if isempty(out) && !text
        # a phrase, rather than a name or the words of a heading, is more likely in the text
        out = find_docs(query; internal, limit, text=true)::String
        FOUND[] && (out = "(No name or heading matches, so these are from the text of the docs.)\n" * out)
        return out
    end
    if isempty(out)
        FOUND[] = false
        out = "Nothing matches $(repr(query)).\n"
    end
    return out * unloaded_note(b.cat)
end

function load_project_packages(b::Browser)
    for id in b.cat.unloaded
        @attempt Core.eval(Main, :(import $(Symbol(id.name)))) nothing
    end
    HEADLESS[] = nothing # the catalog was made before the packages were loaded
end

# What could not be searched, so that a miss is not taken for an answer.
function unloaded_note(cat::Catalog)
    unloaded = [id.name for id in cat.unloaded]
    n = length(unloaded)
    isempty(unloaded) && return ""
    return "(The names of " * (n == 1 ? "a package" : "$n packages") *
        " of the project that " * (n == 1 ? "is" : "are") * " not loaded were not searched: " *
        "$(join(first(unloaded, 5), ", "))$(n > 5 ? ", …" : ""). " *
        "To load " * (n == 1 ? "it" : "them") * ", which runs " * (n == 1 ? "its" : "their") * " code, " *
        (CLI[] ? "add `--load`" : "pass `load=true`") * ".)\n"
end

# Sections of the manuals of the project's packages whose heading, or the title of their page,
# has every word of `query`, or with `text`, pages whose text has them. As
# `(address, package, heading, file)`.
function search_package_manuals(b::Browser, query::AbstractString; text::Bool=false)
    words = lowercase.(split(query))
    isempty(words) && return Tuple{String,String,String,String}[]
    has_all(s) = (l = lowercase(s); all(w -> occursin(w, l), words))
    out = Tuple{String,String,String,String}[]
    for m in package_manuals(b), (pg, ref) in zip(m.pages, m.refs)
        has_all(pg.title) && push!(out, (ref, m.name, pg.title, pg.path))
        for h in page_headings(b.cat, pg.path)
            h.text != pg.title && has_all(h.text) &&
                push!(out, (string(ref, '#', isempty(h.id) ? slugify(h.text) : h.id), m.name, h.text, pg.path))
        end
        if text && !any(r -> r[4] == pg.path, out)
            content = @attempt read(pg.path, String) ""
            has_all(content) && push!(out, (ref, m.name, pg.title, pg.path))
        end
    end
    return out
end

"""
    DocBrowser.list_names(mod; internal=false, load=false) -> String

The names of module `mod` (a module, or its name), by kind. Each says whether it is exported
or public, which package it comes from when it is re-exported, and whether it is documented.
"""
function list_names(mod::Union{Module,AbstractString}; internal::Bool=false, load::Bool=false)
    FOUND[] = true
    b = headless_browser()
    if !(mod isa Module)
        t = agent_target(b.cat, String(mod), Main)
        if t isa LoadTarget && isempty(t.then)
            load || return "$(mod) is not loaded. To load it, which runs its code, $(load_hint()).\n"
            Core.eval(Main, :(import $(Symbol(t.id.name))))
            HEADLESS[] = nothing
            return invokelatest(list_names, mod; internal)
        end
        t isa ModuleTarget || (FOUND[] = false; return "$(mod) is not a module.\n")
        mod = t.mod
    end
    io = IOBuffer()
    println(io, "# ", display_name(mod))
    dir = pkgdir(mod)
    dir === nothing || println(io, "Path: ", dir)
    kind = :none
    for e in module_entries(b.cat, mod)
        (internal || e.vis !== :internal) && !e.deprecated || continue
        if e.kind !== kind
            kind = e.kind
            println(io, "\n", kind_title(kind))
        end
        print(io, "  ", e.name, "  ", e.vis)
        from = reexported_from(e)
        from === nothing || print(io, ", from ", display_name(from))
        e.documented || print(io, ", undocumented")
        println(io)
    end
    return String(take!(io))
end

# What `query` names: a place, a file of a manual, or a name in a loaded module or in a
# package of the active project that is not loaded.
function agent_target(cat::Catalog, query::String, ctx::Module)
    s = strip(query)
    isempty(s) && return nothing
    t = place_target(s, cat)
    t === nothing || return t
    m = match(r"^(.+?\.md)(?:#(.*))?$", s)
    m !== nothing && isfile(m[1]) && return ManualTarget(normpath(m[1]), something(m[2], ""))
    parts = split(s, '.')
    if all(p -> !isempty(p) && Base.isidentifier(p), parts[1:end-1]) && valid_name_part(parts[end])
        roots = Module[ctx, Main, Base, Core]
        for m in values(Base.loaded_modules)
            nameof(m) === Symbol(parts[1]) && pushfirst!(roots, m)
        end
        unloaded = findfirst(id -> id.name == parts[1], cat.unloaded)
        load = unloaded === nothing ? nothing :
            LoadTarget(cat.unloaded[unloaded], length(parts) > 1 ? join(parts[2:end], '.') : "")
        for root in unique!(roots)
            t = name_target(root, root === ctx || root === Main || root === Base || root === Core ?
                                  parts : parts[2:end])
            t === nothing && continue
            # An internal name of Base, such as its `Downloads`, does not hide a package of the project.
            load !== nothing && root !== ctx && root in (Base, Core) &&
                !Base.ispublic(root, Symbol(parts[1])) && return load
            return t
        end
        load === nothing || return load
        # A name that a package of the project exports, as after `using` it.
        for e in cat.pkgs
            e.role in (:project, :direct) && Base.isexported(e.mod, Symbol(parts[1])) || continue
            t = name_target(e.mod, parts)
            t === nothing || return t
        end
    end
    return place_target("docs: " * s, cat)
end

function name_target(root::Module, parts)
    isempty(parts) && return ModuleTarget(root)
    m = root
    for p in parts[1:end-1]
        visible_binding(m, Symbol(p)) || return nothing
        v = getglobal(m, Symbol(p))
        v isa Module || return nothing
        m = v
    end
    sym = Symbol(parts[end])
    visible_binding(m, sym) || return nothing
    v = getglobal(m, sym)
    return v isa Module ? ModuleTarget(v) : NameTarget(m, sym)
end

# The page to show for a target, and the heading of it to start at.
function page_key(cat::Catalog, @nospecialize(t))
    t isa ModuleTarget && return (t, 0)
    t isa LoadTarget && return (t, 0)
    t isa ManualTarget && return (ManualTarget(t.path, ""), anchor_heading(cat, t.path, t.anchor))
    if t isa NameTarget
        e = @attempt classify(cat, t.mod, t.name) nothing
        if e === nothing
            # an internal name that the module only imported is listed under its owner
            owner = @attempt which(t.mod, t.name) t.mod
            e = @attempt classify(cat, owner, t.name) nothing
        end
        return (e, 0)
    end
    return (nothing, 0)
end

# A number for each link among `lines` that leads somewhere `lookup` can go, the same number
# for links to the same place.
function link_numbers(b::Browser, key, p::Page, lines)
    refs = String[]
    numbers = Dict{Int,Int}()
    for (i, s) in enumerate(p.spots)
        s.line in lines || continue
        ref = link_ref(b, key, s.target)
        ref === nothing && continue
        n = findfirst(==(ref), refs)
        n === nothing && (push!(refs, ref); n = length(refs))
        numbers[i] = n
    end
    return refs, numbers
end

function link_ref(b::Browser, key, @nospecialize(t))
    t isa NameTarget && return string(display_name(t.mod), '.', t.name)
    t isa ModuleTarget && return display_name(t.mod)
    t isa URLTarget && return t.url
    t isa LoadTarget && return isempty(t.then) ? t.id.name : string(t.id.name, '.', t.then)
    if t isa ManualTarget
        # what `show` takes, then the file, which can be read directly
        ref = page_ref(t.path)
        if ref === nothing
            pkg = package_page(b, t.path)
            ref = pkg === nothing ? nothing : pkg[2]
        end
        ref === nothing && return isempty(t.anchor) ? t.path : string(t.path, '#', t.anchor)
        return string(ref, isempty(t.anchor) ? "" : "#" * t.anchor, "  ", t.path)
    end
    if t isa AnchorTarget
        ref = key isa ManualTarget ? place_ref(b.cat, key, t.heading) : nothing
        return ref === nothing ? "§$(t.heading) of this page (section $(t.heading))" : ref
    end
    return nothing
end

# The column after which the mark of a link goes: after the link, or after the code it is in,
# so that the code stays as it is written.
function mark_col(line::AnnotatedString, cols::UnitRange{Int})
    str = String(line)
    for a in annotations(line)
        a.label === :face && a.value === :markdown_inlinecode || continue
        r = a.region
        start = textwidth(SubString(str, 1, prevind(str, first(r)))) + 1
        stop = textwidth(SubString(str, 1, thisind(str, last(r))))
        start <= last(cols) <= stop && return stop
    end
    return last(cols)
end

# `s` with each text put after the column it goes with.
function insert_marks(s::String, marks::Vector{Tuple{Int,String}})
    isempty(marks) && return s
    sort!(marks)
    io = IOBuffer()
    col, k = 0, 1
    for c in s
        print(io, c)
        col += textwidth(c)
        while k <= length(marks) && marks[k][1] <= col
            print(io, marks[k][2])
            k += 1
        end
    end
    for j in k:length(marks)
        print(io, marks[j][2])
    end
    return String(take!(io))
end

const AGENT_USAGE = """
    Julia's documentation, as plain text: the manual, and the docstrings of the packages in a
    project, at the versions it uses.

    usage: jldocs <command> [options] [+ <command> [options] ...]
           jldocs -                       (commands from standard input, one a line)
           julia -m DocBrowser ...        (the same, without the app)

      find <words> [--text] [--internal] [--limit N] [--load]
          Names, and sections of Julia's manual and of the project's packages' manuals, that
          match, one a line, each something `show` takes. `--text` looks in the text of
          docstrings and manuals too, as is done anyway when nothing else matches.
      show <query> [--outline] [--section N] [--brief] [--width N] [--load]
          The page for a name (`Base.sort!`), a module (`Plots`), a page of Julia's manual
          (`manual/arrays#Broadcasting`) or of a package's (`GLMakie/explanations/figure`),
          as plain text. Links end in a number, listed at the end in a form `show` takes.
          `--outline` lists the numbered headings of a long page, and of a package its
          manual's pages; `--section N` gives one of them, and `--brief` the start of each
          docstring. `show manual` lists the pages of Julia's manual, and `show GLMakie/`
          those of a package's. `Path:` gives the local file the page comes from, which can
          be read directly.
      names <module> [--internal] [--load]
          The names of a module, by kind, and whether each is exported or public.

    The project is the one the current directory is in, or the one `--project PATH` names. Its
    packages are not loaded without `--load`, which runs their code; until then their pages show
    what their source documents, such as the README, and `find` does not know their names.
    Julia's manual is downloaded the first time it is needed.

    Several commands in one call, split by `+` or one a line for `-`, start Julia and load the
    packages once, which is most of the time a command takes. Each answer then starts with a
    `## jldocs <command>` line. `--project` and `--load` are for all of them.

    Exit codes: 0 for an answer, 1 when nothing was found, 2 for a mistake in the command.
    """

# The options of each command, and those that take a value.
const AGENT_OPTIONS = Dict("show" => ["--outline", "--section", "--brief", "--width", "--load"],
                           "find" => ["--text", "--internal", "--limit", "--load"],
                           "names" => ["--internal", "--load"])
const VALUE_OPTIONS = ("--section", "--width", "--limit", "--project")

# A Pkg app runs in an environment of its own, but the documentation to show is that of the
# project it is run in, as `--project=@.` finds it, unless Julia was given a project already.
function use_project!(path::Union{Nothing,String})
    path === nothing && Base.ACTIVE_PROJECT[] !== nothing && return
    dir = abspath(something(path, pwd()))
    proj = isfile(dir) ? dir : Base.current_project(dir)
    proj === nothing && (proj = Base.load_path_expand("@v#.#"))
    proj === nothing && return
    for env in ("@stdlib", "@v#.#", proj)
        env in LOAD_PATH || pushfirst!(LOAD_PATH, env)
    end
    Base.ACTIVE_PROJECT[] = proj
    return
end

struct AgentCommand
    cmd::String
    query::String
    flags::Set{String}
    values::Dict{String,String}
end

function (@main)(args::Vector{String})
    any(in(("help", "--help", "-h")), args[1:min(1, end)]) && (print(stdout, AGENT_USAGE); return 0)
    CLI[] = true
    isempty(args) && (print(stderr, AGENT_USAGE); return 1)
    # Several commands share one start of Julia and one load of the packages, each split from
    # the next by `+`, or read from standard input one a line for `-`.
    groups = Vector{String}[]
    for a in [args; "+"]
        isempty(groups) && push!(groups, String[])
        a == "+" ? push!(groups, String[]) : push!(groups[end], a)
    end
    pop!(groups)
    if any(==(["-"]), groups)
        lines = filter!(!isempty, split.(readlines(stdin)))
        i = findfirst(==(["-"]), groups)
        groups = [groups[1:i-1]; [String.(l) for l in lines]; groups[i+1:end]]
    end
    # Every command is checked before any is run, so that a mistake costs no time.
    project = nothing
    cmds = AgentCommand[]
    for g in groups
        c = parse_command(g)
        c isa String && return usage_error(c)
        p = get(c.values, "--project", nothing)
        if p !== nothing
            project === nothing || project == p || return usage_error("the commands name different projects")
            project = p
        end
        push!(cmds, c)
    end
    use_project!(project)
    # so that a command before the one with `--load` does not miss the packages
    any(c -> "--load" in c.flags, cmds) && load_project_packages(headless_browser())
    found = true
    for (i, c) in enumerate(cmds)
        if length(cmds) > 1
            i > 1 && println(stdout)
            println(stdout, "## jldocs ", c.cmd, " ", c.query,
                    join((" " * f for f in sort!(collect(c.flags)))),
                    join((" $k $v" for (k, v) in sort!(collect(c.values)) if k != "--project")))
        end
        # a command before can have loaded packages, whose methods are newer than this call
        print(stdout, invokelatest(run_command, c))
        found &= FOUND[]
    end
    return found ? 0 : 1
end

# A command and its options, which can come before or after it, or what is wrong with them.
function parse_command(args::Vector{String})
    words = String[]
    flags = Set{String}()
    values = Dict{String,String}()
    i = 1
    while i <= length(args)
        a = args[i]
        if a in VALUE_OPTIONS
            i < length(args) || return "`$a` needs a value"
            values[a] = args[i+1]
            i += 1
        elseif startswith(a, "--project=")
            values["--project"] = String(chopprefix(a, "--project="))
        elseif startswith(a, "--")
            push!(flags, a)
        else
            push!(words, a)
        end
        i += 1
    end
    isempty(words) && return "a command is missing, as before or after a `+`"
    cmd = popfirst!(words)
    haskey(AGENT_OPTIONS, cmd) || return "there is no command `$cmd`"
    isempty(words) && return "`$cmd` needs something to look for"
    for opt in Iterators.flatten((flags, keys(values)))
        opt == "--project" || opt in AGENT_OPTIONS[cmd] || return "`$cmd` has no option `$opt`"
    end
    for (opt, v) in values
        opt == "--project" || tryparse(Int, v) !== nothing || return "`$opt` needs a number, not `$v`"
    end
    return AgentCommand(cmd, join(words, ' '), flags, values)
end

function run_command(c::AgentCommand)
    flags = c.flags
    number(flag, default) = something(tryparse(Int, get(c.values, flag, "")), default)
    if c.cmd == "show"
        return lookup(c.query; outline="--outline" in flags, section=number("--section", 0), brief="--brief" in flags,
                      width=number("--width", 100), load="--load" in flags)
    elseif c.cmd == "find"
        return find_docs(c.query; text="--text" in flags, internal="--internal" in flags, limit=number("--limit", 20),
                         load="--load" in flags)
    else
        return list_names(c.query; internal="--internal" in flags, load="--load" in flags)
    end
end

function usage_error(msg::String)
    println(stderr, "jldocs: ", msg, ". See `jldocs --help`.")
    return 2
end
