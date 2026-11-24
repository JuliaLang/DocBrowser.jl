# The manual of a package that is installed without it, as a package in a subdirectory of a
# repository is when the manual is elsewhere in the repository. It is downloaded from the
# repository, at the release whose package directory has the tree hash of the installed one:
# in the background when the browser opens, or when asked.

const PKG = PkgId(UUID("44cfe95a-1eb2-52ea-b672-e2afdf69b78f"), "Pkg")

# Downloaded manuals, each kept once by the tree hash of its directory, as packages of one
# repository share theirs, and a record for each installed package version of which manual is
# its, or why it has none.
const PKGDOCS = joinpath("scratchspaces", string(PkgId(@__MODULE__).uuid), "pkgdocs")
tree_dir(depot::String, sha::String) = joinpath(depot, PKGDOCS, "trees", sha)
records_file(depot::String) = joinpath(depot, PKGDOCS, "records.toml")
# a package version's key: the name of the package, and of its directory, which a version has
record_key(dir::String) = basename(dirname(dir)) * "/" * basename(dir)

# The records of every depot, read once. Downloads in the background add to them while pages are
# drawn, so they are read and changed under this lock.
const RECORDS = Ref{Union{Nothing,Dict{String,Dict{String,Any}}}}(nothing)
const RECORDS_LOCK = ReentrantLock()

function records()
    r = RECORDS[]
    r === nothing || return r
    r = Dict{String,Dict{String,Any}}()
    for depot in reverse(DEPOT_PATH)
        f = records_file(depot)
        isfile(f) || continue
        d = @attempt Base.parsed_toml(f) continue
        for (k, v) in d
            v isa Dict{String,Any} && (r[k] = v)
        end
    end
    return RECORDS[] = r
end

record(dir::String) = @lock RECORDS_LOCK get(records(), record_key(dir), nothing)

# Keep records, in the first depot, merged with what other sessions wrote there meanwhile.
function save_records!(new::Dict{String,Dict{String,Any}})
    @lock RECORDS_LOCK begin
        merge!(records(), new)
        f = records_file(first(DEPOT_PATH))
        mkpath(dirname(f))
        old = isfile(f) ? (@attempt Base.parsed_toml(f) Dict{String,Any}()) : Dict{String,Any}()
        tmp = f * ".tmp$(getpid())"
        open(tmp, "w") do io
            for (k, v) in merge(old, new)
                v isa AbstractDict || continue
                println(io, "[", toml_string(k), "]")
                for (field, x) in v
                    println(io, field, " = ", x isa String ? toml_string(x) : x)
                end
                println(io)
            end
        end
        mv(tmp, f; force=true)
        # what was found out before there were records is out of date
        ANY_FETCHED[] = true
    end
    return nothing
end

# The downloaded manual of the package installed at `dir`, if it has one.
function fetched_docs_dir(dir::String)
    any_fetched() || return nothing
    r = record(dir)
    sha = r === nothing ? nothing : get(r, "tree", nothing)
    sha isa String || return nothing
    for depot in DEPOT_PATH
        d = tree_dir(depot, sha)
        isdir(joinpath(d, "docs")) && return d
    end
    return nothing
end

# Whether anything has been downloaded or recorded, in any depot. Every package without a
# manual of its own asks, so this is looked up once, and again after a download.
const ANY_FETCHED = Ref{Union{Nothing,Bool}}(nothing)
function any_fetched()
    a = ANY_FETCHED[]
    a === nothing || return a
    return ANY_FETCHED[] = any(depot -> isdir(joinpath(depot, PKGDOCS)), DEPOT_PATH)
end

# The manual of the package at `dir`: its own, or else the one downloaded for it.
function own_or_fetched_docs(dir::String)
    docs = package_docs(dir)
    isempty(docs.pages) || return docs
    f = fetched_docs_dir(dir)
    return f === nothing ? docs : package_docs(f)
end

# Whether to look for the manual of the package at `dir`, which has none of its own: not when
# it has one downloaded, or cannot have one, or the last try failed less than a day ago.
function wants_manual(dir::String)
    r = record(dir)
    r === nothing && return true
    haskey(r, "none") && return false
    sha = get(r, "tree", nothing)
    sha isa String && return fetched_docs_dir(dir) === nothing
    t = get(r, "failed", 0)
    return !(t isa Integer) || time() - t > 24 * 3600
end

"""
    DocBrowser.fetch_package_docs(pkg) -> String

Download the manual of package `pkg` (a module, or the name of a package of the active project)
when it is not installed with the package, as when the package is in a subdirectory of a
repository whose manual is elsewhere in it, like GLMakie's in Makie.jl. The manual is taken
from the release of the installed version: the tag or commit at which the package's directory
has the tree hash of the installed one. Returns where it is kept. Only GitHub repositories are
supported; a `GITHUB_TOKEN` in the environment raises GitHub's limit on requests.

The browser does this by itself, in the background, for the packages it shows that need it,
unless the environment variable `JULIA_DOCBROWSER_AUTODOWNLOAD` is `no`.
"""
function fetch_package_docs(pkg::Union{Module,AbstractString})
    id = pkg isa Module ? PkgId(pkg) : Base.identify_package(String(pkg))
    id === nothing && error("$pkg is not a package of the active project")
    dir = pkg isa Module ? pkgdir(pkg) : unloaded_dir(id)
    dir === nothing && error("$(id.name) is not installed")
    return fetch_package_docs(id, dir)
end

function fetch_package_docs(id::PkgId, dir::String)
    fetch_manuals([(id, dir)])
    r = record(dir)
    f = fetched_docs_dir(dir)
    f === nothing || return f
    error(r === nothing ? "nothing was downloaded" : string(get(r, "none", get(r, "reason", "nothing was downloaded"))))
end

# The record of a package that cannot have a manual to download. The installed version never will.
no_manual(why::String) = Dict{String,Any}("none" => why)
# The record of a search for a manual that failed. It is tried again after a day.
failed(why::String) = Dict{String,Any}("failed" => round(Int, time()), "reason" => why)

# The owner and name of the GitHub repository at `url`, or `nothing` if it is elsewhere.
function github_repo(url::AbstractString)
    m = match(r"github\.com[/:]([^/]+)/([^/]+?)(?:\.git)?/?$", url)
    return m === nothing ? nothing : (String(m[1]), String(m[2]))
end

# A package whose manual is being looked for.
struct Wanted
    id::PkgId
    dir::String
    owner::String
    repo::String
    subdir::String
end

"""
    fetch_manuals(pkgs; progress) -> Int

Download the manuals of the packages `pkgs`, as `(id, dir)`, that are installed without them,
and record for each what happened. Packages of one repository are looked for together, and a
manual they share is downloaded once. `start(names)` is called with the packages that will be
looked for, if any, and `progress(done, total)` as their repositories are done. Returns how many
packages got a manual. Stops early, recording why, when GitHub's limit on requests is near.
"""
function fetch_manuals(pkgs::Vector{Tuple{PkgId,String}}; start=names -> nothing, progress=(done, total) -> nothing)
    isempty(pkgs) && return 0
    pkg = dynamic(Base.require_stdlib)(PKG)
    new = Dict{String,Dict{String,Any}}()
    # Where each package comes from. A package at the top of its repository, or elsewhere than
    # GitHub, cannot have a manual to download, which stays so for the installed version. The
    # repositories are taken in the order of the packages, which come most wanted first.
    groups = Pair{Tuple{String,String},Vector{Wanted}}[]
    for (id, dir) in pkgs
        place = @attempt registry_place(pkg, id) nothing
        if place === nothing
            new[record_key(dir)] = no_manual("$(id.name) is not in any registry")
            continue
        end
        url, subdir = place::Tuple{String,String}
        key = github_repo(url)
        if key === nothing || isempty(subdir)
            new[record_key(dir)] = no_manual(key === nothing ?
                "only manuals in GitHub repositories can be downloaded, and $(id.name)'s is at $url" :
                "$(id.name) is at the top of its repository, so its manual would be installed with it")
            continue
        end
        i = findfirst(g -> g.first == key, groups)
        i === nothing && (push!(groups, key => Wanted[]); i = length(groups))
        push!(groups[i].second, Wanted(id, dir, key[1], key[2], subdir))
    end
    got = 0
    done = 0
    try
        isempty(groups) || start(String[w.id.name for (_, ws) in groups for w in ws])
        for ((owner, repo), wanted) in groups
            got += fetch_group!(new, pkg, owner, repo, wanted)
            done += 1
            progress(done, length(groups))
        end
    catch err
        err isa InterruptException && rethrow()
        # the rest are tried again another day, rather than each failing on its own
        why = first_line(err)
        for (_, wanted) in groups, w in wanted
            haskey(new, record_key(w.dir)) || (new[record_key(w.dir)] = failed(why))
        end
    finally
        isempty(new) || save_records!(new)
    end
    return got
end

# Find the releases of the packages of one repository, and download the manuals they use.
function fetch_group!(new, pkg::Module, owner::String, repo::String, wanted::Vector{Wanted})
    found, _ = find_releases(pkg, owner, repo, wanted)
    got = 0
    trees = Dict{Tuple{String,String},Union{Nothing,String}}() # (ref, docs) => tree hash
    for w in wanted
        ref = get(found, w.dir, nothing)
        if ref === nothing
            new[record_key(w.dir)] =
                failed("no release of $owner/$repo that was looked at has $(w.id.name) as installed")
            continue
        end
        # The manual is in `docs` at the top of the repository, unless the package says where.
        source = docs_source(w.dir)
        src = source === nothing ? "docs/src" : normpath(joinpath(w.subdir, source))
        if startswith(src, "..")
            new[record_key(w.dir)] = no_manual("$(w.id.name) names a manual outside its repository")
            continue
        end
        docs = dirname(src)
        sha = get!(trees, (ref, docs)) do
            download_tree(owner, repo, ref, docs, relpath(src, docs))
        end
        if sha === nothing
            # which stays so for the installed version
            new[record_key(w.dir)] = no_manual("$owner/$repo has no manual at $src in $ref")
        else
            new[record_key(w.dir)] = Dict{String,Any}("tree" => sha, "source" => "$owner/$repo $ref $docs")
            got += 1
        end
    end
    return got
end

# The release of each of the packages `wanted` of one repository that has one, by the package's
# directory, and the tree hash of each directory as installed.
function find_releases(pkg::Module, owner::String, repo::String, wanted::Vector{Wanted})
    hashes = Dict{String,String}(w.dir => bytes2hex(Base.invokelatest(pkg.GitTools.tree_hash, w.dir)::Vector{UInt8})
                                 for w in wanted)
    found = Dict{String,String}() # dir => ref
    # The tags that the versions suggest are tried first, as they need no listing to find. Only
    # for packages none of them fits are the repository's recent commits and tags listed.
    find_releases!(found, owner, repo, wanted, hashes, guessed_refs(wanted))
    if length(found) < length(wanted)
        rest = Wanted[w for w in wanted if !haskey(found, w.dir)]
        find_releases!(found, owner, repo, wanted, hashes, listed_refs(owner, repo, rest))
    end
    return found, hashes
end

# Look among `refs` for the release of each package not found yet: the one at which its
# directory has the installed tree hash. One listing of a directory at a ref gives the tree hash
# of every package in it. Before asking GitHub's API, which counts against its limit, files of
# the package are read from GitHub's raw files, which do not: a ref at which they differ from
# those installed is passed over.
function find_releases!(found, owner, repo, wanted::Vector{Wanted}, hashes, refs::Vector{String})
    for ref in refs[1:min(end, 30)]
        length(found) == length(wanted) && return
        for parent in unique(String[dirname(w.subdir) for w in wanted if !haskey(found, w.dir)])
            ws = Wanted[w for w in wanted if !haskey(found, w.dir) && dirname(w.subdir) == parent]
            any(w -> same_files(owner, repo, ref, w), first(ws, 3)) || continue
            listing = github_get("repos/$owner/$repo/contents/$parent?ref=$ref")
            listing === nothing && continue
            for w in ws
                entry_sha(listing, basename(w.subdir)) == hashes[w.dir] && (found[w.dir] = ref)
            end
        end
    end
end

# The tags that the packages' versions suggest: of the versions of packages of their repository
# that they pin exactly, as Makie's backends pin Makie's, and of their own versions.
function guessed_refs(wanted::Vector{Wanted})
    refs = String[]
    for w in wanted
        project = package_project(w.dir)
        for (_, c) in get(project, "compat", Dict{String,Any}())
            c isa String && (m = match(r"^=\s*(\d+\.\d+\.\d+)$", c)) !== nothing && push!(refs, "v" * m[1])
        end
        v = get(project, "version", nothing)
        v isa String && push!(refs, "$(basename(w.subdir))-v$v", "v$v")
    end
    return unique!(refs)
end

# The latest commits that changed each package's own directory, among which is the release of
# a package released on its own without a tag, as SciML's often are, then the latest tags.
function listed_refs(owner::String, repo::String, wanted::Vector{Wanted})
    refs = String[]
    for w in wanted
        commits = something(github_get("repos/$owner/$repo/commits?path=$(w.subdir)&per_page=10"), "")
        append!(refs, (String(m[1]) for m in eachmatch(r"\"sha\":\s*\"([0-9a-f]{40})\",\s*\"node_id\"", commits)))
    end
    tags = something(github_get("repos/$owner/$repo/tags?per_page=10"), "")
    append!(refs, (String(m[1]) for m in eachmatch(r"\"name\":\s*\"([^\"]+)\"", tags)))
    return unique!(refs)
end

# Whether the package's project file, and its main source file, are at `ref` as installed. The
# release has them so, and other refs mostly do not.
function same_files(owner::String, repo::String, ref::String, w::Wanted)
    for f in ("Project.toml", joinpath("src", w.id.name * ".jl"))
        local_file = joinpath(w.dir, f)
        isfile(local_file) || continue
        raw_file(owner, repo, ref, w.subdir * "/" * replace(f, '\\' => '/')) == read(local_file, String) || return false
    end
    return true
end

# A file of the repository at `ref`, from GitHub's raw files, or `nothing` when there is none.
const RAW_FILES = Dict{String,Union{Nothing,String}}()
function raw_file(owner::String, repo::String, ref::String, path::String)
    url = "https://raw.githubusercontent.com/$owner/$repo/$ref/$path"
    @lock API_LOCK haskey(RAW_FILES, url) && return RAW_FILES[url]
    text = try
        download_text(url)
    catch err
        is_not_found(err) || rethrow()
        nothing
    end
    @lock API_LOCK RAW_FILES[url] = text
    return text
end

# Download the directory `docs` of the repository at `ref`: its build scripts, and the Markdown
# under `src`. It is kept by its tree hash, so that it is downloaded once for all that use it.
# Returns the tree hash, or `nothing` when there is no such directory.
function download_tree(owner::String, repo::String, ref::String, docs::String, src::String)
    listing = github_get("repos/$owner/$repo/contents/$(dirname(docs))?ref=$ref")
    listing === nothing && return nothing
    sha = entry_sha(listing, basename(docs))
    sha === nothing && return nothing
    any(depot -> isdir(joinpath(tree_dir(depot, sha), "docs")), DEPOT_PATH) && return sha
    tree = something(github_get("repos/$owner/$repo/git/trees/$sha?recursive=1"), "")
    files = String[String(m[1]) for m in eachmatch(r"\"path\":\s*\"([^\"]+)\",\s*\"mode\":\s*\"\d+\",\s*\"type\":\s*\"blob\"", tree)]
    filter!(f -> startswith(f, src * "/") && endswith(f, ".md") || !occursin('/', f) && endswith(f, ".jl"), files)
    isempty(files) && return nothing
    install_dir(tree_dir(first(DEPOT_PATH), sha)) do tmp
        asyncmap(files; ntasks=16) do f
            path = joinpath(tmp, "docs", f)
            mkpath(dirname(path))
            download_url("https://raw.githubusercontent.com/$owner/$repo/$ref/$docs/$f", path)
        end
    end
    return sha
end

# For a package installed without a manual: a button that downloads it, if there is one.
add_fetch_line!(pb::PageBuilder) =
    addline!(pb, "  ", ("manual ", :REPL_DocBrowser_dim), ("not installed", :REPL_DocBrowser_dim), ("  ", nothing),
             ("↓ download it from the repository", nothing, ToggleTarget(:fetch_docs)))

# The repository and subdirectory of package `id`, from the registries Pkg can reach.
function registry_place(pkg::Module, id::PkgId)
    reg = pkg.Registry
    for r in Base.invokelatest(reg.reachable_registries)
        Base.invokelatest(haskey, r, id.uuid)::Bool || continue
        entry = Base.invokelatest(getindex, r, id.uuid)
        # Pkg 1.13 reads the entry through its registry; older versions read it alone.
        info = Base.invokelatest(applicable, reg.registry_info, r, entry)::Bool ?
            Base.invokelatest(reg.registry_info, r, entry) : Base.invokelatest(reg.registry_info, entry)
        repo = info.repo
        repo isa AbstractString || continue
        subdir = info.subdir
        return String(repo), subdir isa AbstractString ? String(subdir) : ""
    end
    error("$(id.name) is not in any registry")
end

# Where the package says its manual is, as `source` in the `[docs]` section of its project file.
function docs_source(dir::String)
    docs = get(package_project(dir), "docs", nothing)
    docs isa AbstractDict || return nothing
    s = get(docs, "source", nothing)
    return s isa String ? s : nothing
end

# The tree hash of the entry `base` in a listing of a directory from GitHub's contents API.
function entry_sha(listing::String, base::AbstractString)
    for m in eachmatch(r"\{[^{}]*\"name\":\s*\"([^\"]+)\"[^{}]*\"sha\":\s*\"([0-9a-f]{40})\"", listing)
        m[1] == base && return String(m[2])
    end
    return nothing
end

"""
    DocBrowser.explain_docs(pkg; online=false, io=stdout)

Say where the browser looked for the documentation of package `pkg` (a module, or the name of
a package of the active project), what it found, and why it did not find more: the manual in
the package's source, its list of pages, a downloaded manual, the `[docs]` section of its
project file, its repository, and the link to its hosted documentation. With `online`, it also
looks for the release of the installed version in the repository, as downloading the manual
does. For package authors, it says what would let the browser find more.
"""
function explain_docs(pkg::Union{Module,AbstractString}; online::Bool=false, io::IO=stdout)
    id = pkg isa Module ? PkgId(Base.moduleroot(pkg)) : Base.identify_package(String(pkg))
    id === nothing && return println(io, "$pkg is not a package of the active project.")
    dir = pkg isa Module ? pkgdir(pkg) : unloaded_dir(id)
    dir === nothing && return println(io, "$(id.name) is not installed.")
    project = package_project(dir)
    v = get(project, "version", nothing)
    println(io, id.name, v isa String ? " $v" : "", "  ", contractuser(dir))
    line(what, text) = println(io, "  ", rpad(what, 16), text)
    hints = String[]
    # the manual in the package's source
    docs = package_docs(dir)
    if isdir(joinpath(dir, "docs"))
        scripts = filter(f -> endswith(f, ".jl"), readdir(joinpath(dir, "docs")))
        lists = [(f, something(doc_page_list(read(joinpath(dir, "docs", f), String)), [])) for f in scripts]
        best = isempty(lists) ? nothing : argmax(x -> length(x[2]), lists)
        line("docs/", "$(length(docs.pages)) pages of a manual")
        if best === nothing || isempty(best[2])
            line("page list", isempty(scripts) ? "no build script in docs/" :
                 "none that is a literal list in $(join(scripts, ", ")); the pages are in file order")
        else
            line("page list", "$(length(best[2])) pages, from docs/$(best[1])")
        end
        isempty(docs.missing) || line("missing", "$(length(docs.missing)) listed pages are not in the source, " *
                                      "such as $(join(first(docs.missing, 3), ", "))")
        isempty(docs.generator) || line("generated", "some pages are written by $(docs.generator) when the docs are built")
    else
        line("docs/", "not in the package's directory")
    end
    # what the package says, and a downloaded manual
    section = get(project, "docs", nothing)
    if section isa AbstractDict
        line("[docs]", join(("$k = $(repr(section[k]))" for k in ("url", "source") if haskey(section, k)), ", "))
    else
        line("[docs]", "none in its project file")
    end
    fetched = fetched_docs_dir(dir)
    r = record(dir)
    line("downloaded", fetched !== nothing ? "$(length(package_docs(fetched).pages)) pages, from $(get(r, "source", "?"))" :
         r === nothing ? (autodownload_enabled() ? "not yet; the browser downloads it when it opens" : "not, as JULIA_DOCBROWSER_AUTODOWNLOAD is no; the button on its page does") :
         haskey(r, "none") ? "cannot be: $(r["none"])" :
         haskey(r, "failed") ? "failed $(round(Int, (time() - r["failed"]) / 3600)) hours ago, and is tried again after a day: $(get(r, "reason", "?"))" :
         "its download is gone; it is downloaded again")
    # where it comes from
    place = try
        registry_place(dynamic(Base.require_stdlib)(PKG), id)
    catch err
        err isa InterruptException && rethrow()
        line("repository", first_line(err))
        nothing
    end
    if place !== nothing
        url, subdir = place
        line("repository", url * (isempty(subdir) ? "" : ", in its subdirectory $subdir"))
        if isempty(docs.pages) && fetched === nothing && !isempty(subdir)
            push!(hints, "The manual is not installed with $(id.name), as Pkg installs only its directory. " *
                         "The browser downloads it from " *
                         (section isa AbstractDict && haskey(section, "source") ? string(section["source"]) : "docs/src at the top of the repository") *
                         ", or `DocBrowser.fetch_package_docs(\"$(id.name)\")` does.")
            section isa AbstractDict && haskey(section, "source") ||
                push!(hints, "Its authors can say where its manual is with `[docs] source = \"../docs/src\"` " *
                             "in its project file, if it is not in docs/src at the top of the repository.")
        end
        if online && !isempty(subdir)
            gh = github_repo(url)
            line("release", gh === nothing ? "not looked for, as only GitHub repositories are supported" :
                 find_release(id, dir, gh..., subdir))
        end
    end
    # the hosted documentation
    link = docs_url(dir)
    own = section isa AbstractDict && haskey(section, "url")
    line("hosted docs", link === nothing ? "no link to them in its README" : "$link, from its " * (own ? "[docs] section" : "README"))
    link === nothing && !own &&
        push!(hints, "Its authors can link its hosted docs with `[docs] url = \"…\"` in its project file.")
    for h in hints
        println(io, "\n", h)
    end
    return nothing
end

# The release that has the package as installed, said in words, as downloading would find it.
function find_release(id::PkgId, dir::String, owner::String, repo::String, subdir::String)
    try
        pkg = dynamic(Base.require_stdlib)(PKG)
        found, hashes = find_releases(pkg, owner, repo, [Wanted(id, dir, owner, repo, subdir)])
        return get(found, dir, "none of the likely tags and commits has its tree hash $(hashes[dir])")
    catch err
        err isa InterruptException && rethrow()
        return "could not be looked for: " * first_line(err)
    end
end

# How many requests GitHub allows before its limit, and when that is renewed, as its last reply
# said. Downloading stops with some to spare, rather than failing part way.
const GITHUB_LEFT = Ref(typemax(Int))
const GITHUB_RESET = Ref(0.0)
const GITHUB_SPARE = 5

# Replies already had in this session, by what was asked. The API is asked once for each.
const API_MEMO = Dict{String,Union{Nothing,String}}()
const API_LOCK = ReentrantLock()

# A reply of GitHub's API, or `nothing` when there is no such thing. Each reply is kept on disk
# with its `ETag`, and asking again with it is answered "not modified" when it is not, which
# does not count against the limit.
function github_get(path::String)
    @lock API_LOCK haskey(API_MEMO, path) && return API_MEMO[path]
    GITHUB_LEFT[] > GITHUB_SPARE || time() > GITHUB_RESET[] ||
        error("GitHub's limit on requests is nearly reached" *
              (isempty(get(ENV, "GITHUB_TOKEN", "")) ? "; a GITHUB_TOKEN raises it" : ""))
    cache = joinpath(first(DEPOT_PATH), PKGDOCS, "api", string(hash(path); base=16))
    etag, kept = "", ""
    if isfile(cache)
        text = read(cache, String)
        i = something(findfirst('\n', text), lastindex(text) + 1)
        etag, kept = text[1:prevind(text, i)], text[nextind(text, i):end]
    end
    headers = ["Accept" => "application/vnd.github+json", "User-Agent" => "DocBrowser.jl"]
    token = get(ENV, "GITHUB_TOKEN", "")
    isempty(token) || push!(headers, "Authorization" => "Bearer $token")
    isempty(etag) || push!(headers, "If-None-Match" => etag)
    io = IOBuffer()
    response = Base.invokelatest(downloader().request, "https://api.github.com/" * path; output=io, headers, throw=false)
    status = response.status::Int
    new_etag = ""
    for (k, v) in response.headers::Vector{Pair{String,String}}
        k = lowercase(k)
        k == "x-ratelimit-remaining" && (GITHUB_LEFT[] = something(tryparse(Int, v), GITHUB_LEFT[]))
        k == "x-ratelimit-reset" && (GITHUB_RESET[] = something(tryparse(Float64, v), GITHUB_RESET[]))
        k == "etag" && (new_etag = v)
    end
    body = if status == 304
        kept
    elseif status == 404
        nothing
    elseif status == 200
        b = String(take!(io))
        isempty(new_etag) || (mkpath(dirname(cache)); write(cache, new_etag * "\n" * b))
        b
    else
        status in (403, 429) && (GITHUB_LEFT[] = 0)
        error("GitHub replied $status to $path")
    end
    @lock API_LOCK API_MEMO[path] = body
    return body
end

## In the background ##

# Downloads that run when the browser opens. Only one runs at a time in a session, and one that
# is running gets a few seconds to finish when Julia exits, as the manual's download does.
const AUTODOWNLOADING = Ref(false)
const AUTODOWNLOAD = Ref{Union{Nothing,Task}}(nothing)
# when the browser last read a key or the mouse, so that the work waits for a pause
const LAST_INPUT = Ref(0.0)
autodownload_enabled() = lowercase(get(ENV, "JULIA_DOCBROWSER_AUTODOWNLOAD", "yes")) ∉ ("no", "false", "0")

# Of the packages the browser lists, loaded and not, those whose manual could be downloaded: the
# project's own dependencies first, as GitHub may allow only so many requests.
function packages_wanting_manuals(pkgs::Vector{PkgEntry}, unloaded::Vector{PkgId})
    out = Tuple{PkgId,String}[]
    for roles in ((:project, :direct), (:indirect,))
        for p in pkgs
            p.role in roles || continue
            dir = pkgdir(p.mod)
            dir === nothing || push!(out, (p.id, dir))
        end
        roles === (:project, :direct) || continue
        for id in unloaded
            dir = unloaded_dir(id)
            dir === nothing || push!(out, (id, dir))
        end
    end
    # The cheapest checks first, as every package is checked on every open: what is recorded,
    # then whether it has a manual of its own. An extension is in the directory of its package,
    # whose project file names the package.
    return filter!(((id, dir),) -> wants_manual(dir) && !isdir(joinpath(dir, "docs")) &&
                                   get(package_project(dir), "name", "") == id.name, unique!(out))
end
