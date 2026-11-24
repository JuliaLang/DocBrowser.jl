# The manuals of packages: the Markdown pages of their Documenter docs, which packages ship
# with their source.

"""
    PackageDocs

The pages of a package's manual that are in its source, in the order of its documentation
build. `missing` are the pages the build lists that are not there, and `generator` the tool
that writes pages while the documentation is built, or `""`. Either means that the manual
shown is not the whole of the online one.
"""
struct PackageDocs
    pages::Vector{ManualPage}
    missing::Vector{String}
    generator::String
end

const NO_DOCS = PackageDocs(ManualPage[], String[], "")

# Tools that write Markdown pages while the docs are built, by the name a script uses for them.
const DOC_GENERATORS = ("Literate", "DemoCards", "Weave", "PlutoStaticHTML", "DocumenterExamples")

# The manual of the package that module `m` is the top of, if it has one.
function package_docs(cat::Catalog, m::Module)
    p = get(cat.bymod, m, nothing)
    (p === nothing || p.role in (:extension, :julia, :main) || parentmodule(m) !== m) && return NO_DOCS
    dir = pkgdir(m)
    dir === nothing && return NO_DOCS
    return get!(() -> own_or_fetched_docs(dir), cat.pkgdocs, dir)::PackageDocs
end

function package_docs(dir::String)
    docs = joinpath(dir, "docs")
    scripts = isdir(docs) ? filter(f -> endswith(f, ".jl"), readdir(docs; join=true)) : String[]
    text = join((read(f, String) for f in scripts), '\n')
    # Documenter reads the pages from `src`, unless the build names another directory.
    m = match(r"\bsource\s*=\s*\"([^\"]+)\"", text)
    src = joinpath(docs, m === nothing ? "src" : m[1])
    generator = something(findfirst(g -> occursin(Regex("\\b$g\\b"), text), DOC_GENERATORS), 0)
    generator = generator == 0 ? "" : DOC_GENERATORS[generator]
    listed = Tuple{String,String,String}[] # file, title, group
    # The list is in the build script, or a file of its own, by their usual names. Failing those,
    # a build can have helper scripts with short lists of their own, so the longest is the manual's.
    usual = filter(f -> basename(f) in ("make.jl", "makedocs.jl", "pages.jl"), scripts)
    for group in (usual, setdiff(scripts, usual))
        for f in group
            lists = doc_page_list(read(f, String))
            lists === nothing || length(lists) > length(listed) && (listed = lists)
        end
        isempty(listed) || break
    end
    pages = ManualPage[]
    missing = String[]
    if isempty(listed)
        files = isdir(src) ? doc_files(src) : String[]
        for f in files
            add_manual_page!(pages, joinpath(src, f), :package, "")
        end
        # A build script with no pages here writes them all.
        isempty(pages) && occursin("makedocs", text) && isempty(generator) && (generator = "a script")
    else
        for (file, title, group) in listed
            path = joinpath(src, file)
            if isfile(path)
                add_manual_page!(pages, path, :package, group)
                isempty(title) || (pages[end] = ManualPage(pages[end].path, title, :package, group))
            else
                push!(missing, file)
            end
        end
    end
    return PackageDocs(pages, missing, generator)
end

# The Markdown files under `src`, the index first.
function doc_files(src::String)
    files = String[]
    for (root, _, fs) in walkdir(src), f in fs
        endswith(f, ".md") && push!(files, relpath(joinpath(root, f), src))
    end
    return sort_by!(files, f -> (f != "index.md", count('/', f) + count('\\', f), f))
end

# The pages that a build script gives `makedocs` as `pages`, as files with the title and group
# they are listed under, or `nothing` if it gives none as a literal list.
function doc_page_list(src::String)
    exprs = @attempt Meta.parseall(src) return nothing
    # The list may be written out elsewhere in the script, and named.
    named = Dict{Symbol,Any}()
    found = Ref{Any}(nothing)
    find_pages!(named, found, exprs)
    list = found[]
    list isa Symbol && (list = get(named, list, nothing))
    is_list(list) || return nothing
    out = Tuple{String,String,String}[]
    add_doc_pages!(out, list, "")
    return isempty(out) ? nothing : out
end

# `[...]`, or a typed list such as `Any[...]`.
is_list(x) = Meta.isexpr(x, :vect) || Meta.isexpr(x, :ref) && x.args[1] isa Symbol
list_items(x::Expr) = Meta.isexpr(x, :vect) ? x.args : x.args[2:end]

find_pages!(named, found, x) = nothing
function find_pages!(named, found, ex::Expr)
    if Meta.isexpr(ex, :(=), 2) && ex.args[1] isa Symbol && is_list(ex.args[2])
        named[ex.args[1]] = ex.args[2]
    end
    if Meta.isexpr(ex, :kw, 2) && ex.args[1] === :pages ||
       Meta.isexpr(ex, :(=), 2) && ex.args[1] === :pages && found[] === nothing
        found[] = ex.args[2]
    end
    for a in ex.args
        find_pages!(named, found, a)
    end
end

function add_doc_pages!(out, list::Expr, group::String)
    for x in list_items(list)
        paths = list_paths(x)
        if paths !== nothing
            append!(out, ((p, "", group) for p in paths))
        elseif Meta.isexpr(x, :call, 3) && x.args[1] === :(=>) && x.args[2] isa String
            title, v = x.args[2]::String, x.args[3]
            paths = list_paths(v)
            if paths === nothing
                is_list(v) && add_doc_pages!(out, v, title)
            elseif length(paths) == 1 && !Meta.isexpr(v, :.)
                push!(out, (paths[1], title, group))
            else
                append!(out, ((p, "", title) for p in paths))
            end
        elseif is_list(x)
            add_doc_pages!(out, x, group)
        end
    end
end

# The files an item of a page list names: a path, or a `joinpath` of literal parts, which a
# build can apply to a list of names with a dot, and splat into the list around it.
function list_paths(@nospecialize(x))::Union{Nothing,Vector{String}}
    x isa String && return String[x]
    x isa Expr || return nothing
    Meta.isexpr(x, :..., 1) && return list_paths(x.args[1])
    if Meta.isexpr(x, :call) && x.args[1] === :joinpath && length(x.args) > 1
        parts = literal_strings(x.args[2:end])
        parts === nothing || return String[join(parts, '/')]
    end
    if Meta.isexpr(x, :., 2) && x.args[1] === :joinpath && Meta.isexpr(x.args[2], :tuple)
        args = (x.args[2]::Expr).args
        if !isempty(args) && is_list(args[end])
            prefix = literal_strings(args[1:end-1])
            names = literal_strings(list_items(args[end]::Expr))
            (prefix === nothing || names === nothing) && return nothing
            return String[join(String[prefix; n], '/') for n in names]
        end
    end
    return nothing
end

# The values of `v` as strings, when all of them are, as known types so that nothing that
# packages add to joining strings changes what is compiled.
function literal_strings(v::Vector{Any})
    out = String[]
    for a in v
        a isa String || return nothing
        push!(out, a)
    end
    return out
end

# The package that a page of its manual belongs to, if it is loaded.
function page_package(cat::Catalog, path::String)
    for (docs, p) in docs_dirs(cat)
        startswith(path, docs) && return p
    end
    return nothing
end

# The directories that the manual of each package can be in: its `docs`, anywhere under which
# a build can name the directory of its pages, and that of a downloaded copy, in any depot.
# Each page of a manual asks, so they are worked out once for the packages there are.
function docs_dirs(cat::Catalog)
    n, dirs = cat.docs_dirs
    n == length(cat.pkgs) && return dirs
    dirs = Tuple{String,PkgEntry}[]
    sep = Base.Filesystem.path_separator
    for p in cat.pkgs
        p.role === :extension && continue
        dir = pkgdir(p.mod)
        dir === nothing && continue
        push!(dirs, (joinpath(dir, "docs") * sep, p))
        fetched = fetched_docs_dir(dir)
        fetched === nothing || push!(dirs, (joinpath(fetched, "docs") * sep, p))
    end
    cat.docs_dirs = (length(cat.pkgs), dirs)
    return dirs
end

# Why a package's manual here lacks pages of its online one, or `nothing`.
function docs_gap(docs::PackageDocs)
    isempty(docs.missing) && isempty(docs.generator) && return nothing
    by = isempty(docs.generator) ? "" : " by $(docs.generator)"
    s = "Some of this manual is written$by when its documentation is built, so it is not in the package's source."
    n = length(docs.missing)
    if n > 0
        shown = join(first(docs.missing, 3), ", ") * (n > 3 ? " and $(n - 3) more" : "")
        s *= " Missing here: $shown."
    end
    return s * " The online docs should have all of it."
end

# The notice of a gap, as a dim paragraph, with a link to the online docs at `url` if known.
function gap_notice!(pb::PageBuilder, docs::PackageDocs, url)
    s = docs_gap(docs)
    s === nothing && return
    words = split("⚠ " * s)
    link = url === nothing ? nothing : findfirst(==("online"), words)
    segs = Any[]
    for (i, w) in enumerate(words)
        if link !== nothing && i == link
            push!(segs, Any[("online docs", nothing, URLTarget(url)), (" ", nothing)])
        elseif link === nothing || i != link + 1
            push!(segs, (w * " ", :REPL_DocBrowser_dim))
        end
    end
    addflow!(pb, "  ", segs)
    addline!(pb)
end

## `@autodocs` ##

# The kinds of names that `@autodocs` lists, in its default order.
const AUTODOCS_ORDER = (:module, :constant, :type, :function, :macro)

# The names that an `@autodocs` block documents, written so that they resolve in `ctx`.
function autodocs_names(code::AbstractString, ctx::Module, cat::Catalog)
    opts = Dict{Symbol,Any}()
    for line in split(code, '\n')
        ex = @attempt Meta.parse(line; raise=false)
        Meta.isexpr(ex, :(=), 2) && ex.args[1] isa Symbol && (opts[ex.args[1]] = ex.args[2])
    end
    mods = Module[]
    for x in autodocs_list(get(opts, :Modules, nothing))
        m = autodocs_module(x, ctx)
        m === nothing || push!(mods, m)
    end
    given = Symbol[]
    for x in autodocs_list(get(opts, :Order, nothing))
        x isa QuoteNode && (x = x.value)
        x isa Symbol && x in AUTODOCS_ORDER && push!(given, x)
    end
    order = isempty(given) ? collect(AUTODOCS_ORDER) : given
    pages = String[x for x in autodocs_list(get(opts, :Pages, nothing)) if x isa String]
    public, private = get(opts, :Public, true) !== false, get(opts, :Private, true) !== false
    names = String[]
    for m in mods
        meta = something(Base.Docs.meta(m; autoinit=false), IdDict{Any,Any}())
        picked = NameEntry[]
        for e in module_entries(cat, m)
            e.documented && e.mod === m && (e.kind === :global ? :constant : e.kind) in order || continue
            (e.vis === :internal ? private : public) || continue
            if !isempty(pages)
                docs = get(meta, Base.Docs.Binding(m, e.name), nothing)
                docs isa Base.Docs.MultiDoc || continue
                any(d -> d isa DocStr && any(p -> endswith(as_string(string(get(d.data, :path, ""))), p), pages),
                    values(docs.docs)) || continue
            end
            push!(picked, e)
        end
        rank(e) = something(findfirst(==(e.kind === :global ? :constant : e.kind), order), 0)
        sort_by!(picked, e -> (rank(e), lowercase(String(e.name))))
        for e in picked
            push!(names, m === ctx ? String(e.name) : string(display_name(m), '.', e.name))
        end
    end
    return names
end

autodocs_list(x) = is_list(x) ? list_items(x) : Any[]

# The module that `Modules = [...]` names, as the page's module sees it.
function autodocs_module(x, ctx::Module)
    parts = Symbol[]
    while Meta.isexpr(x, :., 2) && x.args[2] isa QuoteNode
        pushfirst!(parts, x.args[2].value)
        x = x.args[1]
    end
    x isa Symbol || return nothing
    pushfirst!(parts, x)
    m = parts[1] === nameof(ctx) ? ctx : isdefined(ctx, parts[1]) ? getglobal(ctx, parts[1]) : nothing
    for p in parts[2:end]
        m isa Module && isdefined(m, p) || return nothing
        m = getglobal(m, p)
    end
    return m isa Module ? m : nothing
end

## Packages that are not loaded ##

# Where a package that is not loaded is, as the environment would load it.
function unloaded_dir(id::PkgId)
    path = dynamic(Base.locate_package)(id)::Union{Nothing,String}
    return path === nothing ? nothing : dirname(dirname(path))
end

# The manual of a package that is not loaded, read from its source.
function unloaded_docs(cat::Catalog, id::PkgId)
    dir = unloaded_dir(id)
    return dir === nothing ? NO_DOCS : get!(() -> own_or_fetched_docs(dir), cat.pkgdocs, dir)::PackageDocs
end

# The names that the manual of a package that is not loaded lists.
unloaded_package_names(cat::Catalog, id::PkgId) = String[n for (n, i) in unloaded_names(cat) if i == id]

# The package that is not loaded which the manual page `path` is from, or `nothing`.
function unloaded_owner(cat::Catalog, path::String)
    if in_stdlib_dir(path)
        id = Base.identify_package(stdlib_name(path))
        return id === nothing || haskey(Base.loaded_modules, id) ? nothing : id
    end
    for id in cat.unloaded
        dir = unloaded_dir(id)
        dir !== nothing && startswith(path, joinpath(dir, "docs") * Base.Filesystem.path_separator) && return id
    end
    return nothing
end
