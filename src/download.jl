# Julia's releases do not ship the Markdown source of the manual, so it is downloaded from the
# Julia repository on first use, at the commit this Julia was built from, and kept in the depot.

const JULIA_RAW = "https://raw.githubusercontent.com/JuliaLang/julia"

# Loaded only when the manual is downloaded, since it brings in libcurl and OpenSSL.
const DOWNLOADS = PkgId(UUID("f43a241f-c20a-4ad4-852c-f6b1247861c6"), "Downloads")
# Exit hooks run last first. The one that waits for a download must run before the one that
# closes the downloader, so it is set once the downloader is loaded.
const downloader = OncePerProcess{Module}() do
    m = dynamic(Base.require_stdlib)(DOWNLOADS)
    atexit(wait_for_download)
    return m
end
download_url(url, out) = Base.invokelatest(downloader().download, url, out)
is_not_found(err) = err isa downloader().RequestError && err.response.status == 404

# A string as TOML has it. `repr` would write `\$`, which TOML cannot read.
toml_string(s::AbstractString) =
    string('"', replace(s, '\\' => "\\\\", '"' => "\\\"", r"[\x00-\x1f\x7f]" => ' '), '"')

julia_ref() = (c = Base.GIT_VERSION_INFO.commit; isempty(c) ? "v$VERSION" : c)

# Where to look for the manual, nearest first. A local build or a fork can be at a commit
# that is not on GitHub, so then it is the release's tag, or for a development version its
# release branch or master.
function manual_refs()
    refs = [julia_ref()]
    v = VERSION
    "DEV" in v.prerelease || push!(refs, "v$v")
    push!(refs, "release-$(v.major).$(v.minor)", "master")
    return unique!(refs)
end

# The first of `refs` that has the manual, and its `doc/make.jl`.
function find_manual_ref(refs)
    for ref in refs
        try
            return ref, String(take!(download_url("$JULIA_RAW/$ref/doc/make.jl", IOBuffer())))
        catch err
            is_not_found(err) || rethrow()
        end
    end
    error("Julia's manual was not found at any of $(join(refs, ", "))")
end

# The version of the manual that was downloaded, if it is not the one this Julia was built from.
function manual_source(dir::String=manual_dir())
    file = joinpath(dir, "source.txt")
    return isfile(file) ? strip(read(file, String)) : nothing
end

# Where the manual was downloaded to, in any depot, or else where to download it. A Pkg app
# runs with a depot of its own first, ahead of the one the browser downloaded the manual to.
function downloaded_manual_dir()
    rel = joinpath("scratchspaces", string(PkgId(@__MODULE__).uuid), "manual", julia_ref())
    for depot in DEPOT_PATH
        dir = joinpath(depot, rel)
        isfile(joinpath(dir, "pages.toml")) && return dir
    end
    return joinpath(first(DEPOT_PATH), rel)
end

# The page lists of `doc/make.jl`, which are literal vectors of paths, as `pages.toml` has them.
function make_page_lists(src::AbstractString)
    lists = Dict{String,Any}("manual" => String[], "base" => String[], "devdocs" => Any[])
    paths(ex) = String[p for p in (x isa String ? x : Meta.isexpr(x, :call, 3) && x.args[1] === :(=>) &&
                                   x.args[3] isa String ? x.args[3] : nothing for x in ex.args) if p !== nothing]
    for ex in Meta.parseall(src).args
        Meta.isexpr(ex, :(=), 2) && Meta.isexpr(ex.args[2], :vect) || continue
        name, v = ex.args[1], ex.args[2]
        if name === :Manual
            lists["manual"] = paths(v)
        elseif name === :BaseDocs
            lists["base"] = paths(v)
        elseif name === :DevDocs
            for g in v.args
                Meta.isexpr(g, :call, 3) && g.args[1] === :(=>) && g.args[2] isa String &&
                    Meta.isexpr(g.args[3], :vect) || continue
                push!(lists["devdocs"], Dict{String,Any}("title" => g.args[2], "pages" => paths(g.args[3])))
            end
        end
    end
    return lists
end

function write_pages_toml(io::IO, lists)
    printlist(ps) = join(("    " * toml_string(p) for p in ps), ",\n")
    println(io, "manual = [\n", printlist(lists["manual"]), "\n]\n")
    println(io, "base = [\n", printlist(lists["base"]), "\n]\n")
    for g in lists["devdocs"]
        println(io, "[[devdocs]]\ntitle = ", toml_string(g["title"]), "\npages = [\n", printlist(g["pages"]), "\n]\n")
    end
end

"""
    DocBrowser.download_manual(; force=false) -> String

Download the Markdown source of Julia's manual for this version of Julia, and return the
directory it is kept in. If the commit Julia was built from is not on GitHub, the nearest
version is downloaded instead: the release's tag, or its release branch, or master. The
browser does this by itself the first time it opens. If Julia has the manual installed, this
returns where it is, without downloading anything.
"""
function download_manual(; force::Bool=false)
    installed = installed_manual_dir()
    installed === nothing || return installed
    dir = downloaded_manual_dir()
    isfile(joinpath(dir, "pages.toml")) && !force && return dir
    ref, make = find_manual_ref(manual_refs())
    base = "$JULIA_RAW/$ref"
    fetch(rel) = String(take!(download_url("$base/$rel", IOBuffer())))
    lists = make_page_lists(make)
    rels = [lists["manual"]; lists["base"]; (p for g in lists["devdocs"] for p in g["pages"])...]
    tmp = mktempdir(mkpath(dirname(dir)))
    try
        asyncmap(rels; ntasks=16) do rel
            path = joinpath(tmp, rel)
            mkpath(dirname(path))
            # a page that is missing is left out, as when it is not installed
            try
                download_url("$base/doc/src/$rel", path)
            catch err
                rm(path; force=true)
                is_not_found(err) || rethrow()
            end
        end
        # The release notes are at the top of the repository; the docs build copies them in.
        write(joinpath(tmp, "NEWS.md"), fetch("NEWS.md"))
        open(io -> write_pages_toml(io, lists), joinpath(tmp, "pages.toml"), "w")
        ref == julia_ref() || write(joinpath(tmp, "source.txt"), ref)
        force && rm(dir; force=true, recursive=true)
        mv(tmp, dir; force=true)
    catch
        rm(tmp; force=true, recursive=true)
        rethrow()
    end
    return dir
end

# The download that a browser started, so that only one runs at a time, and why the last one
# failed, if it did.
const MANUAL_DOWNLOAD = Ref{Union{Nothing,Task}}(nothing)
const MANUAL_ERROR = Ref{Union{Nothing,String}}(nothing)
# What to call when the running download ends: one for each browser that asked for it.
const MANUAL_WAITERS = Any[]
const DOWNLOADING = Ref(false)
# The download runs on another thread, so all of the above is read and changed under this.
const DOWNLOAD_LOCK = ReentrantLock()

# Start downloading the manual in the background, unless it is being downloaded, and call
# `on_done` when it is done or has failed. A download that fails can be tried again.
function start_manual_download(on_done)
    @lock DOWNLOAD_LOCK begin
        push!(MANUAL_WAITERS, on_done)
        DOWNLOADING[] && return nothing
        DOWNLOADING[] = true
        MANUAL_ERROR[] = nothing
        downloader()
        MANUAL_DOWNLOAD[] = errormonitor(Threads.@spawn run_manual_download())
    end
    return nothing
end

function run_manual_download()
    failure = try
        dynamic(download_manual)()
        nothing
    catch err
        @debug "Downloading the manual failed" exception=(err, catch_backtrace())
        first_line(err)
    end
    @lock DOWNLOAD_LOCK MANUAL_ERROR[] = failure
    while true
        # The download is over only once nobody is left to tell, so that nobody is missed.
        on_done = @lock DOWNLOAD_LOCK begin
            isempty(MANUAL_WAITERS) && (DOWNLOADING[] = false; break)
            popfirst!(MANUAL_WAITERS)
        end
        Base.invokelatest(on_done)
    end
end

# `:downloading`, `:failed`, or `:none` when no download has run or the last one worked.
function manual_status()
    @lock DOWNLOAD_LOCK begin
        MANUAL_ERROR[] === nothing || return :failed
        return DOWNLOADING[] ? :downloading : :none
    end
end

# Julia can crash if it exits while a download is running, so a running one gets a few seconds
# to finish first.
function wait_for_download()
    for t in @lock DOWNLOAD_LOCK (MANUAL_DOWNLOAD[], AUTODOWNLOAD[])
        t === nothing || istaskdone(t) || within(() -> wait(t), 5.0)
    end
    return nothing
end
