using Test
using REPL
import StyledStrings
# The browser downloads package manuals by itself when it opens, which tests must not.
ENV["JULIA_DOCBROWSER_AUTODOWNLOAD"] = "no"
# Loading the browser should not load Downloads, unless something already has.
const DOWNLOADS_PRELOADED = haskey(Base.loaded_modules,
    Base.PkgId(Base.UUID("f43a241f-c20a-4ad4-852c-f6b1247861c6"), "Downloads"))
using Random
using Markdown
using DocBrowser: DocBrowser, KeyEvent, MouseEvent, PasteEvent, read_event, Catalog,
    module_entries, search, resolve_ref, NameTarget, ModuleTarget, entry_page, module_page,
    Browser, frame, handle!, browse

isdefined(Test, :detect_closure_boxes) && @test isempty(Test.detect_closure_boxes(DocBrowser))

DOWNLOADS_PRELOADED || @test !haskey(Base.loaded_modules, DocBrowser.DOWNLOADS)
# The tests of the manual need its pages, which releases of Julia do not include.
# Downloaded first, so that no download is still running when the tests end.
@test isdir(DocBrowser.download_manual())

include("FakeTerminals.jl")
import .FakeTerminals.FakeTerminal

# The browser's settings and hooks, which the tests change, to put back at the end for the tests
# that run after these in the same process.
const SETTINGS = (DocBrowser.URL_OPENER, DocBrowser.EDITOR, DocBrowser.COPY, DocBrowser.FIRST_OPEN,
                  DocBrowser.SEARCH_INDIRECT, DocBrowser.LAYOUT, DocBrowser.LAST)
const SAVED = map(r -> r[], SETTINGS)
# Start from the defaults, whatever earlier tests in this process did with the browser.
DocBrowser.FIRST_OPEN[] = true
DocBrowser.SEARCH_INDIRECT[] = false
DocBrowser.LAYOUT[] = :auto
DocBrowser.LAST[] = nothing

"""
Fixture

A module for testing the browser. See [`Fixture.documented`](@ref) and `helper`.
"""
module Fixture
export documented, Point, @mac, Inner
public undocumented_public, documented_public

"""
    documented(x)

Calls [`documented_public`](@ref). See also `helper` and [`Base.sum`](https://docs.julialang.org).
"""
documented(x) = x

"Public but not exported."
documented_public(x) = x
undocumented_public(x) = x

"Internal, but documented."
helper() = nothing
private_undocumented() = nothing

"A point."
struct Point
    x::Int
end

"A macro."
macro mac() end

"An inner module."
module Inner
    export inner_fn
    "Inside."
    inner_fn() = 1
end
end

module UndocumentedExt end

strip_ansi(s) = replace(s, r"\e\[[0-9;?]*[a-zA-Z]|\e\]8;[^\e]*\e\\\\" => "")

# Input over a slow connection: each part arrives only once the reader waits for more.
mutable struct SlowInput <: IO
    buf::IOBuffer
    parts::Vector{String}
end
SlowInput(first::String, rest::String...) = SlowInput(IOBuffer(first), collect(rest))
Base.bytesavailable(s::SlowInput) = bytesavailable(s.buf)
function Base.eof(s::SlowInput)
    eof(s.buf) || return false
    isempty(s.parts) && return true
    s.buf = IOBuffer(popfirst!(s.parts))
    return false
end
Base.read(s::SlowInput, ::Type{UInt8}) = (eof(s) && throw(EOFError()); read(s.buf, UInt8))
Base.peek(s::SlowInput, ::Type{UInt8}) = (eof(s) && throw(EOFError()); peek(s.buf, UInt8))

@testset "input decoding" begin
    ev(s) = read_event(IOBuffer(s))
    @test ev("q") == KeyEvent('q')
    @test ev("\r") == KeyEvent(:enter)
    @test ev("\x7f") == KeyEvent(:backspace)
    @test ev("\x03") == KeyEvent('c', DocBrowser.CTRL)
    @test ev("\e") == KeyEvent(:escape)
    @test ev("\e[A") == KeyEvent(:up)
    # Alt and an arrow, from a terminal that sends Escape before the arrow's sequence.
    @test ev("\e\e[D") == KeyEvent(:left, DocBrowser.ALT)
    @test ev("\e\e") == KeyEvent(:escape)
    @test ev("\eOB") == KeyEvent(:down)
    @test ev("\e[1;3D") == KeyEvent(:left, DocBrowser.ALT)
    @test ev("\e[5~") == KeyEvent(:pageup)
    @test ev("\e[Z") == KeyEvent(:backtab, DocBrowser.SHIFT)
    @test ev("\eb") == KeyEvent('b', DocBrowser.ALT)
    @test ev("\e[<0;12;7M") == MouseEvent(:press, 1, 7, 12, 0)
    @test ev("\e[<0;12;7m") == MouseEvent(:release, 1, 7, 12, 0)
    @test ev("\e[<35;3;4M") == MouseEvent(:move, 4, 4, 3, 0)
    @test ev("\e[<65;3;4M") == MouseEvent(:wheeldown, 0, 4, 3, 0)
    @test ev("\e[<128;3;4M") == MouseEvent(:press, 8, 4, 3, 0)
    @test ev("\e[200~some text\e[201~") == PasteEvent("some text")
    # A paste whose end marker is lost ends when no more input comes.
    @test DocBrowser.read_paste(IOBuffer("some text"), 0.01) == PasteEvent("some text")
    # Replies to terminal queries are skipped, but for whether it is dark and its background.
    @test ev("\e]11;rgb:0000/0000/0000\e\\") == DocBrowser.SchemeEvent(nothing, "rgb:0000/0000/0000")
    @test ev("\e]10;rgb:ffff/ffff/ffff\a") === nothing
    @test ev("\e[?997;1n") == DocBrowser.SchemeEvent(true, "")
    @test ev("\e[?62;22c") === nothing
    # A mouse report in the X10 encoding is read whole, and its bytes are not keys.
    io = IOBuffer("\e[M #!q")
    @test read_event(io) == DocBrowser.LegacyMouseEvent() && read_event(io) == KeyEvent('q')
    # xterm.js's report for a place it cannot name ends at its `m`, not at the `N`.
    io = IOBuffer("\e[<0;NaN;NaNmq")
    @test read_event(io) === nothing && read_event(io) == KeyEvent('q')
    # Alt with a key that can start a sequence, and an unterminated string, swallow nothing.
    @test ev("\e]") == KeyEvent(']', DocBrowser.ALT)
    @test ev("\eO") == KeyEvent('O', DocBrowser.ALT)
    io = IOBuffer("\e]11;rgb")
    @test read_event(io) === nothing && eof(io)
    # A sequence split across two reads, as over a slow connection, is still one key. The rest
    # arrives as soon as the reader waits for it, and the reader may wait long, so that how soon
    # its waiting task runs on a busy machine does not matter.
    DocBrowser.SEQUENCE_WAIT[] = 60.0
    try
        @test read_event(SlowInput("\e", "[A")) == KeyEvent(:up)
        @test read_event(SlowInput("\e[", "A")) == KeyEvent(:up)
    finally
        DocBrowser.SEQUENCE_WAIT[] = 0.03
    end
    # After a click closes the browser, its release is read rather than left for the prompt.
    io = IOBuffer("\e[<35;3;4M\e[<0;79;26mabc")
    DocBrowser.await_release(io)
    @test read(io, String) == "abc"
end

@testset "catalog" begin
    md = "text\n```@docs\nPkg.activate\nBase.sum(itr)\n@time\n```\n```julia\nnot_this\n```\n"
    @test DocBrowser.docs_block_names(md) == ["Pkg.activate", "Base.sum", "@time"]
    cat = Catalog()
    @test any(p -> p.mod === Base && p.role === :julia, cat.pkgs)
    @test any(p -> p.mod === REPL, cat.pkgs)
    entries = Dict(e.name => e for e in module_entries(cat, Fixture))
    @test entries[:documented].vis === :exported
    @test entries[:documented].kind === :function
    @test entries[:documented].documented
    @test entries[:documented_public].vis === :public
    @test !entries[:undocumented_public].documented
    # Another name for something documented is documented too.
    @test all(s -> DocBrowser.classify(cat, Base, s).documented, (:Cvoid, :÷, :ComplexF64))
    @test entries[:helper].vis === :internal
    # A module is marked as its parent has it, and a package as exported.
    @test DocBrowser.module_entry(cat, Base._RepeatInnerOuter).vis === :internal
    @test DocBrowser.module_entry(cat, Base.Iterators).vis === :exported
    @test DocBrowser.module_entry(cat, REPL).vis === :exported
    @test entries[:Point].kind === :type
    @test entries[Symbol("@mac")].kind === :macro
    @test entries[:Inner].kind === :module
    @test !haskey(entries, :eval) && !haskey(entries, :include)
    # Results are grouped by kind: modules, types, functions, macros.
    kinds = [e.kind for e in module_entries(cat, Fixture)]
    @test issorted(kinds; by = k -> findfirst(==(k), DocBrowser.KINDS))

    @test resolve_ref("documented_public", Fixture, cat) == NameTarget(Fixture, :documented_public)
    @test resolve_ref("helper()", Fixture, cat) == NameTarget(Fixture, :helper)
    @test resolve_ref("Base.sum", Fixture, cat) == NameTarget(Base, :sum)
    @test resolve_ref("Fixture.Inner", @__MODULE__, cat) == ModuleTarget(Fixture.Inner)
    @test resolve_ref("private_undocumented", Fixture, cat) === nothing
    @test resolve_ref("x", Fixture, cat) === nothing
    @test resolve_ref("1 + 2", Fixture, cat) === nothing

    hits = search(cat, "sum")
    @test !isempty(hits)
    @test first(hits).name === :sum && first(hits).mod === Base
    @test all(e -> e.vis !== :internal, hits)
    @test any(e -> e.vis === :internal, search(cat, "sum"; internal=true))
    # A dotted query searches inside matching modules only.
    @test all(e -> last(fullname(e.mod)) === :Iterators, search(cat, "Iterators.fla"))
end

@testset "pages" begin
    # Lines keep their annotations, as `split` gives them.
    str = Base.AnnotatedString("ab\n\nc∀\nd", [(1:6, :face, :bold), (5:7, :face, :italic), (10:10, :face, :red)])
    lines = DocBrowser.split_lines(str)
    @test String.(lines) == ["ab", "", "c∀", "d"]
    faces(l) = join((string(l[a.region], '=', a.value) for a in Base.annotations(l)), ' ')
    @test faces.(lines) == ["ab=bold", "", "c∀=bold c∀=italic", "d=red"]
    cat = Catalog()
    e = only(filter(e -> e.name === :documented, module_entries(cat, Fixture)))
    p = entry_page(cat, e, 70)
    text = join(map(String, p.lines), '\n')
    @test occursin("Calls documented_public", text)
    targets = [s.target for s in p.spots]
    @test NameTarget(Fixture, :documented_public) in targets
    @test NameTarget(Fixture, :helper) in targets
    @test DocBrowser.URLTarget("https://docs.julialang.org") in targets
    @test p.source !== nothing && endswith(p.source.file, "runtests.jl")
    @test all(l -> textwidth(String(l)) <= 70 || occursin("runtests.jl", String(l)), p.lines)

    p = module_page(cat, Fixture, 70)
    text = join(map(String, p.lines), '\n')
    @test occursin("A module for testing the browser.", text)
    @test occursin("Submodules", text)
    @test ModuleTarget(Fixture.Inner) in [s.target for s in p.spots]
end

function fake_terminal(input::String; rows=30, cols=110)
    out = IOContext(IOBuffer(), :displaysize => (rows, cols), :color => true)
    return FakeTerminal(IOBuffer(input), out, IOBuffer())
end

@testset "drawing" begin
    for (rows, cols) in ((30, 120), (24, 80), (20, 50), (4, 10))
        b = Browser(fake_terminal(""; rows, cols))
        lines = frame(b)
        @test length(lines) == rows
        @test all(l -> textwidth(strip_ansi(l)) == cols, lines)
    end
    b = Browser(fake_terminal(""))
    lines = strip_ansi.(frame(b))
    @test occursin("Julia docs", lines[1])
    # The active project is named in the header, when there is one.
    label = DocBrowser.project_label()
    @test label === nothing || occursin("($label)", lines[1])
    @test occursin("Contents", lines[2])
    @test any(l -> occursin("Base", l), lines)
end

@testset "navigation" begin
    b = Browser(fake_terminal(""))
    frame(b)
    DocBrowser.follow!(b, NameTarget(Fixture, :documented))
    @test b.mod === Fixture
    @test DocBrowser.current_key(b).name === :documented
    # A public name without a docstring is not dimmed, which would make it look internal.
    i = findfirst(r -> r.entry !== nothing && r.entry.name === :undocumented_public, b.name_rows)
    @test !any(a -> a.value === :REPL_DocBrowser_dim, Base.annotations(DocBrowser.list_line(b, :names, i, 1, 40, 2)))
    @test b.focus === :doc
    frame(b)
    # Step through the links and follow the first one.
    handle!(b, KeyEvent(:tab))
    @test b.link > 0
    handle!(b, KeyEvent(:enter))
    @test DocBrowser.current_key(b).name === :documented_public
    handle!(b, KeyEvent(:backspace))
    @test DocBrowser.current_key(b).name === :documented
    handle!(b, KeyEvent(']'))
    @test DocBrowser.current_key(b).name === :documented_public

    # Internal names are hidden until asked for.
    DocBrowser.show_module!(b, Fixture)
    names_shown() = [r.entry.name for r in b.name_rows if r.entry !== nothing]
    @test !(:helper in names_shown())
    handle!(b, KeyEvent('i'))
    @test :helper in names_shown()

    # Entering a submodule from the names list, and stepping back out with ←.
    b.focus = :names
    b.names.cursor = findfirst(r -> r.entry !== nothing && r.entry.name === :Inner, b.name_rows)
    handle!(b, KeyEvent(:enter))
    @test b.mod === Fixture.Inner
    handle!(b, KeyEvent(:left))
    @test b.mod === Fixture

    # Search, then open the top result.
    handle!(b, KeyEvent('/'))
    for c in "documented_pub"
        handle!(b, KeyEvent(c))
    end
    @test b.typing
    @test first(b.results).name === :documented_public
    handle!(b, KeyEvent(:enter))
    @test !b.typing && b.query === nothing
    @test DocBrowser.current_key(b).name === :documented_public

    # Clicking the title of the names pane selects the module itself.
    lines = frame(b)
    pane = only(filter(p -> p[1] === :names, DocBrowser.layout(b)))
    row = findfirst(l -> occursin(r"\d+ names", strip_ansi(l)), lines)
    handle!(b, MouseEvent(:press, 1, row, pane[2] + 3, 0))
    @test b.focus === :names && b.names.cursor == 1
end

@testset "browse" begin
    # `y` closes the browser and returns the name that was shown.
    @test browse(fake_terminal("y"); query="sum") == "sum"
    @test browse(fake_terminal("y"); query="Base.Iterators") == "Iterators"
    # A place in the docs opens there, written short or as the address of the online docs.
    @test browse(fake_terminal("y"); query="docs: Base.Iterators") == "Iterators"
    @test browse(fake_terminal("y"); query="https://docs.julialang.org/en/v1/base/collections/#Base.sum") == "sum"
    # An unknown name starts a search; Enter opens the first result.
    @test browse(fake_terminal("\ry"); query="iterators.flatte") == "Base.Iterators.flatten"
    # `q` closes without picking anything, as does running out of input.
    @test browse(fake_terminal("jjlq")) === nothing
    @test browse(fake_terminal("\e[<0;10;5M\e[<0;10;5m/abc\e")) === nothing
    # The terminal is put back the way it was found.
    t = fake_terminal("q")
    browse(t)
    out = String(take!(t.out_stream.io))
    @test occursin("\e[?1049h", out) && endswith(out, DocBrowser.LEAVE_SCREEN)
    # A burst of keys already waiting is drawn once, at its end, and here it ends by quitting.
    @test count("\e[?2026h", out) == 1
    # Each row drawn is a line deleted and put back first, inside a scroll region that is the
    # whole screen.
    @test occursin("\e[?2026h\e[r\e[1;1H\e[M\e[L", out)
end

@testset "loading a project dependency" begin
    # A dependency of the project that is not loaded yet: a package made for the test, with a
    # depot of its own for its cache, so that loading it changes nothing that later tests see.
    mktempdir() do dir
        name = "DocBrowserLoadTest"
        uuid = Base.UUID("5d9c9a4e-3b0e-4f53-9c1e-6c1f2a7b8d10")
        pkg = joinpath(dir, name)
        mkpath(joinpath(pkg, "src"))
        write(joinpath(pkg, "Project.toml"), "name = \"$name\"\nuuid = \"$uuid\"\n")
        write(joinpath(pkg, "src", "$name.jl"), "\"A package to load from the browser.\"\nmodule $name\nend\n")
        # and one that fails to load
        bad, baduuid = "DocBrowserLoadFails", Base.UUID("5d9c9a4e-3b0e-4f53-9c1e-6c1f2a7b8d12")
        mkpath(joinpath(dir, bad, "src"))
        write(joinpath(dir, bad, "Project.toml"), "name = \"$bad\"\nuuid = \"$baduuid\"\n")
        write(joinpath(dir, bad, "src", "$bad.jl"), "module $bad\nerror(\"cannot load\")\nend\n")
        # and one that a link names a function in
        link, linkuuid = "DocBrowserLoadLink", Base.UUID("5d9c9a4e-3b0e-4f53-9c1e-6c1f2a7b8d17")
        mkpath(joinpath(dir, link, "src"))
        write(joinpath(dir, link, "Project.toml"), "name = \"$link\"\nuuid = \"$linkuuid\"\n")
        write(joinpath(dir, link, "src", "$link.jl"), "module $link\nexport hello\n\"Says hello.\"\nhello() = 1\nend\n")
        mkpath(joinpath(dir, link, "docs", "src"))
        write(joinpath(dir, link, "docs", "src", "index.md"), "# $link\n\n```@docs\nhello\n```\n")
        write(joinpath(dir, link, "README.md"), "# $link\n\nA package to read about before loading it.\n")
        env = joinpath(dir, "env")
        mkpath(env)
        write(joinpath(env, "Project.toml"), "[deps]\n$name = \"$uuid\"\n$bad = \"$baduuid\"\n$link = \"$linkuuid\"\n")
        write(joinpath(env, "Manifest.toml"), """
            manifest_format = "2.0"
            [[deps.$name]]
            uuid = "$uuid"
            path = "$(replace(pkg, '\\' => '/'))"
            [[deps.$bad]]
            uuid = "$baduuid"
            path = "$(replace(joinpath(dir, bad), '\\' => '/'))"
            [[deps.$link]]
            uuid = "$linkuuid"
            path = "$(replace(joinpath(dir, link), '\\' => '/'))"
            """)
        old = Base.active_project()
        pushfirst!(DEPOT_PATH, joinpath(dir, "depot"))
        try
            # A package that is the active project, as when working on it, is listed as the
            # project, and its manual is searched before it is loaded.
            Base.set_active_project(joinpath(dir, link, "Project.toml"))
            b = Browser(fake_terminal(""))
            lid = Base.PkgId(linkuuid, link)
            @test lid in b.cat.unloaded
            @test only(r for r in b.side_rows if r.unloaded == lid).role === :project
            @test any(r -> r[1] == "$link/index", DocBrowser.search_package_manuals(b, link))
            @test occursin("$link is the active project", join(String.(DocBrowser.page(b, DocBrowser.LoadTarget(lid), 80).lines), '\n'))
            Base.set_active_project(joinpath(env, "Project.toml"))
            b = Browser(fake_terminal(""))
            id = Base.PkgId(uuid, name)
            @test id in b.cat.unloaded
            row = findfirst(r -> r.unloaded == id, b.side_rows)
            @test row !== nothing
            b.side.cursor = row - 1
            DocBrowser.move!(b, :side, 1)
            @test DocBrowser.current_key(b) == DocBrowser.LoadTarget(id)
            # The names of the module shown before are not listed under it, but a row saying it
            # is not loaded, which → moves to as for any package.
            @test occursin("$name  not loaded", String(DocBrowser.pane_title(b, :names, 1, 40)))
            listed = String.(DocBrowser.draw_list(b, :names, 1, 40))
            @test all(isempty ∘ strip, listed)
            b.focus = :side
            handle!(b, KeyEvent(:right))
            @test b.focus === :names && DocBrowser.current_key(b) == DocBrowser.LoadTarget(id)
            # and where ⏎ loads it, as on its row in the contents
            b.live = true
            handle!(b, KeyEvent(:enter))
            # It loads in a task, in a panel that says it is precompiling, and the browser can
            # be used meanwhile, but not closed.
            @test DocBrowser.loading(b)
            screen = join(strip_ansi.(frame(b)), '\n')
            @test occursin("julia> import $name", screen) && occursin("Precompiling $name…", screen)
            handle!(b, KeyEvent('i')); handle!(b, KeyEvent('i'))
            DocBrowser.load_package!(b, id)
            @test startswith(b.status, "Already precompiling $name")
            handle!(b, KeyEvent('q'))
            DocBrowser.stay_open!(b)
            @test !b.quit && occursin("can close once it is done", b.status)
            wait(b.load_task)
            @test Base.root_module_exists(id)
            # Once precompiled, it is loaded under a notice over the page, gone when it is done.
            @test occursin("│   Loading $name…   │", strip_ansi(String(take!(b.out.io)))) && isempty(b.modal)
            @test b.console === nothing && isempty(b.loading)
            @test length(b.cat.unloaded) == 2
            @test DocBrowser.current_key(b) == ModuleTarget(Base.root_module(id))
            @test (@invokelatest getglobal(Main, Symbol(name))) === Base.root_module(id)
            # A package that fails to load leaves the panel up with the error, until the next key.
            DocBrowser.load_package!(b, Base.PkgId(baduuid, bad))
            wait(b.load_task)
            @test any(l -> occursin("cannot load", l), b.console) && startswith(b.status, "Error")
            @test any(l -> occursin("Loading failed", l), strip_ansi.(frame(b)))
            @test occursin("any key close", strip_ansi(frame(b)[end]))
            handle!(b, KeyEvent('j'))
            @test b.console === nothing
            # With the browser on another thread, a load is handed to the thread that opened
            # it, which some packages must be loaded on.
            b.loads = Channel{Task}(1)
            DocBrowser.load_package!(b, Base.PkgId(baduuid, bad))
            t = take!(b.loads)
            @test b.load_task === t && !istaskstarted(t)
            schedule(t); wait(t)
            @test Threads.threadid(t) == Threads.threadid()
            b.loads = nothing
            handle!(b, KeyEvent('j'))
            # A package that is not loaded shows what its source documents: its README, and its
            # manual's pages and the names they list, which load it when picked.
            lid = Base.PkgId(linkuuid, link)
            page = join(String.(DocBrowser.page(b, DocBrowser.LoadTarget(lid), 80).lines), '\n')
            @test occursin("read about before loading it", page) && occursin("Load $link", page)
            row = findfirst(r -> r.unloaded == lid, b.side_rows)
            b.side.cursor = row - 1
            DocBrowser.move!(b, :side, 1)
            kinds = [r.kind for r in b.name_rows]
            @test :pkgpage in kinds && DocBrowser.LoadTarget(lid, "$link.hello") in [r.target for r in b.name_rows]
            index = only(r for r in b.name_rows if r.kind === :pkgpage).hit.path
            shown = join(String.(DocBrowser.page(b, DocBrowser.ManualTarget(index, ""), 80).lines), '\n')
            @test occursin("$link is not loaded", shown)
            # A search finds the names that the manual of a package that is not loaded lists.
            foreach(c -> handle!(b, KeyEvent(c)), "/hello")
            i = findfirst(r -> r.kind === :unloaded, b.name_rows)
            @test i !== nothing && b.name_rows[i].target == DocBrowser.LoadTarget(Base.PkgId(linkuuid, link), "$link.hello")
            @test occursin(r"hello +DocBrowserLoadLink", strip_ansi(String(DocBrowser.list_line(b, :names, i, 1, 60, 2))))
            handle!(b, KeyEvent(:escape))
            # A `docs:` link to a name in a package that is not loaded, as shared from another
            # session, loads the package and then opens the name.
            t = DocBrowser.place_target("docs: $link.hello", b.cat)
            @test t == DocBrowser.LoadTarget(Base.PkgId(linkuuid, link), "$link.hello")
            DocBrowser.follow!(b, t)
            wait(b.load_task)
            key = DocBrowser.current_key(b)
            @test key isa DocBrowser.NameEntry && key.name === :hello
            b.live = false
        finally
            popfirst!(DEPOT_PATH)
            Base.set_active_project(old)
        end
    end
end

@testset "READMEs without their badges" begin
    mktempdir() do dir
        path = joinpath(dir, "README.md")
        write(path, "# Pkg\n\n[![][ci-img]][ci-url] [![][docs-img]][docs-url]\n\nWhat it does.\n\n[ci-img]: https://example.org/ci.svg\n[ci-url]: https://example.org/ci\n")
        text = sprint(show, MIME("text/plain"), DocBrowser.readme_markdown(path))
        @test occursin("What it does.", text) && !occursin("ci-img", text) && !occursin("example.org", text)
    end
end

@testset "repository links" begin
    @test DocBrowser.web_url("git@github.com:JuliaLang/Foo.jl.git") == "https://github.com/JuliaLang/Foo.jl"
    @test DocBrowser.web_url("https://gitlab.com/a/b.git/") == "https://gitlab.com/a/b"
    @test DocBrowser.web_url("/home/me/Foo.jl") === nothing
    @test DocBrowser.web_url("https://me:token@github.com/a/Private.jl.git") == "https://github.com/a/Private.jl"
    id = Base.PkgId(Base.UUID(UInt128(1)), "NotARealPackage")
    mktempdir() do dir
        # A developed package is found through its git remote.
        mkpath(joinpath(dir, ".git"))
        write(joinpath(dir, ".git", "config"), """
            [core]
            \tbare = false
            [remote "origin"]
            \turl = git@github.com:someone/NotARealPackage.jl.git
            """)
        @test DocBrowser.repo_url(id, dir) == "https://github.com/someone/NotARealPackage.jl"
    end
    # Without a repository, the page offers a web search for the package.
    p = DocBrowser.unloaded_page(Catalog(), id, 70)
    @test DocBrowser.URLTarget("https://duckduckgo.com/?q=NotARealPackage.jl") in [s.target for s in p.spots]
    @test any(l -> occursin("NotARealPackage.jl", String(l)), p.lines)
end

"""
    Shape

An abstract shape.

# Examples

```jldoctest
julia> 1 + 1
2
```

# Notes

Uses Example.jl.

# Extended help

More detail here.
"""
abstract type Shape end
"A square."
struct Square <: Shape
    side::Float64
end
area(s::Square) = s.side^2

@testset "pages: methods, types, examples, contents" begin
    cat = Catalog()
    entry(m, s) = only(filter(e -> e.name === s, module_entries(cat, m)))
    text(p) = join(map(String, p.lines), '\n')
    targets(p) = [s.target for s in p.spots]

    p = entry_page(cat, entry(Base, :sum), 90)
    @test occursin(r"Methods \(\d+\)", text(p))
    @test any(t -> t isa DocBrowser.SourceTarget, targets(p))

    p = entry_page(cat, entry(@__MODULE__, :Shape), 90)
    t = text(p)
    @test occursin("Subtypes (1)", t) && occursin("Square", t)
    @test !occursin("More detail here.", t) && occursin("Show the extended help", t)
    @test DocBrowser.ToggleTarget(:methodswith) in targets(p)
    # The example can be pasted, and package mentions are links.
    @test DocBrowser.CodeTarget("1 + 1") in targets(p)
    @test any(t -> t isa DocBrowser.URLTarget && occursin("Example.jl", t.url), targets(p))
    @test length(p.headings) == 2

    # With the extended help there are enough headings for a list of contents.
    p = entry_page(cat, entry(@__MODULE__, :Shape), 90, Set([:extended, :methodswith]))
    @test length(p.headings) == 3 && DocBrowser.AnchorTarget(3) in targets(p)
    @test occursin("More detail here.", text(p))
    @test occursin("Methods that take this type", text(p))

    p = entry_page(cat, entry(@__MODULE__, :Square), 90)
    @test occursin(r"side\s*::\s*Float64", text(p))
    @test occursin("Constructors", text(p))

    @test DocBrowser.paste_text(["  julia> x = 1", "  1", "", "  julia> f(x,", "             y)"]) ==
        "x = 1\nf(x,\n    y)"
    @test DocBrowser.paste_text(["  sum(x)"]) == "sum(x)"
    @test DocBrowser.licence(pkgdir(DocBrowser)) == "MIT"
    @test DocBrowser.licence(mktempdir()) === nothing
end

@testset "text search, toggles and layout" begin
    cat = Catalog()
    hits = DocBrowser.search_text(cat, "eigenvalue decomposition")
    @test any(e -> e.name === :eigen, hits) || !isdefined(Main, :LinearAlgebra)
    @test any(e -> e.name === :sum, DocBrowser.search_text(cat, "sum of all elements"))

    b = Browser(fake_terminal(""))
    frame(b)
    # A search looks at everything, and says nothing of what it looks in: the names that only
    # the text of their docstrings matches come after the names.
    handle!(b, KeyEvent('/'))
    for c in "sum of"
        handle!(b, KeyEvent(c))
    end
    @test b.searchmode === :all && !isempty(b.text_results)
    @test any(r -> r.kind === :header && r.group === :text_hits, b.name_rows)
    header = strip_ansi(frame(b)[1])
    @test occursin("sum of", header) && !occursin("⇄", header)
    # ^T narrows it to names, then to text, then looks at everything again.
    handle!(b, KeyEvent('t', DocBrowser.CTRL))
    @test b.searchmode === :names && isempty(b.text_results) && occursin("names ⇄", strip_ansi(frame(b)[1]))
    handle!(b, KeyEvent('t', DocBrowser.CTRL))
    @test b.searchmode === :text && !isempty(b.results)
    handle!(b, KeyEvent('t', DocBrowser.CTRL))
    @test b.searchmode === :all
    handle!(b, KeyEvent(:escape))

    DocBrowser.follow!(b, NameTarget(@__MODULE__, :Shape))
    frame(b)
    handle!(b, KeyEvent('x'))
    @test :extended in DocBrowser.page_flags(b, DocBrowser.current_key(b))
    handle!(b, KeyEvent('}'))
    @test b.doc_scroll > 0

    handle!(b, KeyEvent('w'))
    @test b.layout === :three
    handle!(b, KeyEvent('w'))
    @test length(DocBrowser.layout(b)) == 2
    handle!(b, KeyEvent('w'))
    @test length(DocBrowser.layout(b)) == 1
    handle!(b, KeyEvent('w'))
    @test b.layout === :auto
end

@testset "browse objects, reopening, no colour" begin
    @test browse(fake_terminal("y"), sum) == "sum"
    @test browse(fake_terminal("y"), Base.Iterators) == "Iterators"
    @test browse(fake_terminal("y"), 1.5) == "Float64"
    # With nothing to go to, the browser opens where it was last closed.
    @test browse(fake_terminal("y")) == "Float64"

    out = IOContext(IOBuffer(), :displaysize => (30, 110), :color => false)
    b = Browser(FakeTerminal(IOBuffer(""), out, IOBuffer(), false))
    @test !b.color
    lines = frame(b)
    @test !any(l -> occursin('\e', l), lines)
    @test any(l -> occursin('▶', l), lines)
end

@testset "finding the source" begin
    b = Browser(fake_terminal(""))
    frame(b)
    src(x) = DocBrowser.source_of(b, x)
    entry(m, s) = only(filter(e -> e.name === s, module_entries(b.cat, m)))
    # A documented name goes to its docstring, an undocumented one to its first method.
    @test endswith(src(entry(Fixture, :documented)).file, "runtests.jl")
    @test src(entry(Fixture, :undocumented_public)) ==
        DocBrowser.method_target(only(methods(Fixture.undocumented_public)))
    @test src(NameTarget(Base, :sum)) isa DocBrowser.SourceTarget
    @test endswith(src(ModuleTarget(DocBrowser)).file, "DocBrowser.jl")
    @test src(DocBrowser.URLTarget("https://julialang.org")) === nothing
    m = first(methods(sum))
    @test src(DocBrowser.method_target(m)) == DocBrowser.method_target(m)
    # Rows of the lists are found from where they are drawn.
    row = findfirst(r -> r.pkg !== nothing, b.side_rows)
    @test DocBrowser.hit_subject(b, (:side, row)) === b.side_rows[row].pkg
    # Right-clicking where nothing has a source says so.
    handle!(b, MouseEvent(:press, 3, 1, 1, 0))
    @test b.status == "No source location for that"
end

@testset "discoverability" begin
    DocBrowser.FIRST_OPEN[] = true
    b = Browser(fake_terminal(""; cols=120))
    footer() = strip_ansi(frame(b)[end])
    # The first open shows a tip, until the first key.
    @test occursin("right-click opens its source", footer())
    handle!(b, KeyEvent('j'))
    @test !occursin("Tip:", footer())
    @test occursin("? help", footer()) && occursin("q quit", footer())

    # Hovering or selecting a link says where it goes.
    DocBrowser.follow!(b, NameTarget(Fixture, :documented))
    lines = frame(b)
    p = DocBrowser.page(b, DocBrowser.current_key(b), DocBrowser.doc_width(b))
    k = findfirst(s -> s.target isa DocBrowser.URLTarget, p.spots)
    b.hover = (:spot, k)
    @test occursin("in your web browser", footer())
    # Going to another page forgets what was under the pointer on the old one.
    DocBrowser.follow!(b, NameTarget(Base, :sum))
    frame(b)
    @test b.hover === nothing
    DocBrowser.follow!(b, NameTarget(Fixture, :documented))
    frame(b)
    handle!(b, KeyEvent(:tab))
    @test occursin("right-click: source", footer())
    @test DocBrowser.describe(b, (:load, Base.PkgId(Base.UUID(UInt128(1)), "Foo"))) ==
        "↓ runs import Foo, then shows its documentation"

    # Hints follow what the page offers.
    DocBrowser.follow!(b, NameTarget(@__MODULE__, :Shape))
    frame(b)
    @test occursin("x extended", footer()) && occursin("{ } headings", footer())
    handle!(b, KeyEvent('/'))
    @test occursin("^T names", footer())
    handle!(b, KeyEvent(:escape))

    # Narrow terminals keep `? help` and offer other layouts.
    b = Browser(fake_terminal(""; cols=70))
    handle!(b, KeyEvent('j'))
    @test occursin("? help", footer()) && occursin("w layout", footer())

    # Without colour the legend matches the letters in the list.
    out = IOContext(IOBuffer(), :displaysize => (30, 130), :color => false)
    b = Browser(FakeTerminal(IOBuffer(""), out, IOBuffer(), false))
    DocBrowser.show_module!(b, Fixture)
    legend = frame(b)[end-1]
    @test occursin("E exported", legend) && !occursin("internal", legend)
    handle!(b, KeyEvent('i'))
    @test occursin("- internal", frame(b)[end-1])

    # A name from another package is marked as a re-export, but Base's names from Core are not.
    entry(m, owner) = DocBrowser.NameEntry(m, :x, :function, :exported, true, owner)
    @test DocBrowser.reexported_from(entry(Fixture, Base)) === Base
    @test DocBrowser.reexported_from(entry(Base, Core)) === nothing
    @test DocBrowser.reexported_from(entry(Base, Base.Iterators)) === nothing
end

@testset "JLL pages" begin
    # A JLL that Julia has loaded already, so that the test loads nothing new.
    jlls = filter(m -> endswith(String(nameof(m)), "_jll"), Base.loaded_modules_array())
    m = isempty(jlls) ? Base.require(Main, :Zlib_jll) : first(jlls)
    cat = Catalog()
    p = module_page(cat, m, 90)
    t = join(map(String, p.lines), '\n')
    @test occursin("binary wrapper", t) && occursin("Libraries", t)
    @test DocBrowser.URLTarget("https://github.com/JuliaBinaryWrappers/$(nameof(m)).jl") in [s.target for s in p.spots]
    @test !any(s -> s.target isa DocBrowser.URLTarget && occursin("docs.julialang.org", s.target.url), p.spots)
end

# Nothing a test does may launch a web browser or an editor.
const OPENED = String[]
const EDITED = Tuple{String,Int}[]
DocBrowser.URL_OPENER[] = url -> push!(OPENED, url)
DocBrowser.EDITOR[] = (file, line) -> push!(EDITED, (file, line))
const COPIED = String[]
DocBrowser.COPY[] = (b, text) -> (push!(COPIED, text); "to the clipboard")

function test_browser(; rows=30, cols=120)
    b = Browser(fake_terminal(""; rows, cols))
    empty!(b.cat.unloaded) # so no click loads a package
    DocBrowser.refresh_side!(b)
    frame(b)
    return b
end
press!(b, keys...) = for k in keys
    handle!(b, k isa KeyEvent ? k : KeyEvent(k))
    frame(b)
end

@testset "keys in the lists" begin
    b = test_browser()
    n = length(b.side_rows)
    press!(b, :end);      @test b.side.cursor == n
    press!(b, :home);     @test b.side.cursor == 1
    press!(b, 'G');       @test b.side.cursor == n
    press!(b, 'g');       @test b.side.cursor == 1
    press!(b, :pagedown); @test b.side.cursor == min(n, 1 + DocBrowser.content_rows(b))
    press!(b, :pageup);   @test b.side.cursor == 1
    # The first row is the start page, and the next the heading of the documentation:
    # Enter and → fold it, and fold it back.
    @test DocBrowser.on_start(b)
    press!(b, :down);     @test DocBrowser.is_header(DocBrowser.side_row(b))
    press!(b, :enter);    @test !(:docs in b.expanded) && length(b.side_rows) < n
    press!(b, :right);    @test :docs in b.expanded
    press!(b, 'a');       @test all(in(b.expanded), DocBrowser.SECTION_ORDER)
    press!(b, 'a');       @test !(:indirect in b.expanded)
    # On a package, → moves to its names, and ← back again.
    b.side.cursor = findfirst(r -> r.pkg !== nothing, b.side_rows)
    DocBrowser.sync_side!(b)
    press!(b, :right);    @test b.focus === :names
    press!(b, :left);     @test b.focus === :side
    press!(b, KeyEvent('l', DocBrowser.CTRL))
    @test isempty(b.prev) || length(b.prev) == b.height
    press!(b, :tab);      @test b.focus === :names
    press!(b, :tab);      @test b.focus === :doc
    # In the documentation ⇧⇥ steps through links. ← goes back to the list that chose the page.
    press!(b, :left);     @test b.focus === :side
    press!(b, :backtab);  @test b.focus === :names
    # Group headings in the names pane fold too.
    DocBrowser.follow!(b, ModuleTarget(Base))
    b.focus = :names
    b.names.cursor = findfirst(r -> r.kind === :header, b.name_rows)
    group = b.name_rows[b.names.cursor].group
    press!(b, :enter);    @test group in b.collapsed
    press!(b, :enter);    @test !(group in b.collapsed)
end

@testset "selecting text" begin
    b = test_browser()
    DocBrowser.follow!(b, NameTarget(Fixture, :documented))
    frame(b)
    p = DocBrowser.page(b, DocBrowser.current_key(b), DocBrowser.doc_width(b))
    li = findfirst(l -> occursin("Calls", String(l)), p.lines)
    line = String(p.lines[li])
    x = only(l[2] for l in DocBrowser.layout(b) if l[1] === :doc)
    # The screen position of a column of the page line `l`.
    at(l, col) = (l - b.doc_scroll + 2, x + col - 1)
    calls = textwidth(line[1:prevind(line, findfirst("Calls", line)[1])]) + 1
    mouse(action, (row, col); button=1) = (handle!(b, MouseEvent(action, button, row, col, 0)); frame(b))
    # A drag over text in the page selects and copies it.
    mouse(:press, at(li, calls))
    mouse(:drag, at(li, calls + 4))
    @test DocBrowser.selected_cols(b, li) == calls:calls+4
    mouse(:release, at(li, calls + 4))
    @test COPIED[end] == "Calls" && occursin("Copied 5 characters", b.status)
    # Across lines, the indentation of the page is dropped.
    for start in (1, 2) # from the edge of the pane, or from inside the indentation
        mouse(:press, at(li - 2, start))
        mouse(:drag, at(li, calls + 4))
        mouse(:release, at(li, calls + 4))
        @test startswith(COPIED[end], "documented(x)") && endswith(COPIED[end], "\n\nCalls")
    end
    # The highlight leaves out the indentation, which is not copied either.
    w = only(l[3] for l in DocBrowser.layout(b) if l[1] === :doc)
    shown = DocBrowser.draw_doc(b, x, w)[li - b.doc_scroll]
    @test [first(a.region) for a in Base.annotations(shown) if a.value === :REPL_DocBrowser_selection] == [calls]
    # A click selects nothing, a key clears a selection, and Esc only clears it.
    mouse(:press, at(li, calls)); mouse(:release, at(li, calls))
    @test b.sel === nothing
    b.sel = (li, 1, li, 3)
    press!(b, :escape)
    @test b.sel === nothing && !b.quit
    # Two clicks select a word, and three the line.
    b.clicks = (0.0, 0.0, 0.0, 0.0)
    for _ in 1:2
        mouse(:press, at(li, calls + 1)); mouse(:release, at(li, calls + 1))
    end
    @test COPIED[end] == "Calls"
    mouse(:press, at(li, calls + 1)); mouse(:release, at(li, calls + 1))
    @test COPIED[end] == strip(line)
    # A double-click word takes in dots and paths, but not a full stop or spaces.
    @test DocBrowser.word_cols("see Base.sort!.", 6) == 5:14
    @test DocBrowser.word_cols("a  b", 2) === nothing
    @test DocBrowser.col_slice("αβγδ", 2, 3) == "βγ"
end

@testset "copying code" begin
    b = test_browser()
    DocBrowser.follow!(b, NameTarget(@__MODULE__, :Shape))
    frame(b)
    p = DocBrowser.page(b, DocBrowser.current_key(b), DocBrowser.doc_width(b))
    # The example is indented, and has no line of its own to copy it.
    k = findfirst(l -> occursin("julia> 1 + 1", String(l)), p.lines)
    @test startswith(String(p.lines[k]), "    julia>") && startswith(String(p.lines[k+1]), "    2")
    @test !any(l -> occursin("paste at the prompt", String(l)), p.lines)
    # Its ⧉ shows only while the pointer or the cursor is in it.
    x = only(l[2] for l in DocBrowser.layout(b) if l[1] === :doc)
    row = k - b.doc_scroll + 2
    copy_mark() = any(l -> DocBrowser.col_slice(strip_ansi(l), x, x) == "⧉", frame(b))
    @test !copy_mark()
    handle!(b, MouseEvent(:move, 0, row + 1, x + 6, 0))
    @test copy_mark()
    handle!(b, MouseEvent(:move, 0, 1, 1, 0))
    @test !copy_mark()
    # With the cursor in it, ⏎ copies the code and stays, and y puts it at the prompt.
    b.focus = :doc
    b.doc_line = k
    press!(b, :down)
    @test copy_mark() && occursin("⏎ copy code", strip_ansi(frame(b)[end]))
    press!(b, :enter)
    @test COPIED[end] == "1 + 1" && !b.quit && occursin("Copied 1 line of code", b.status)
    press!(b, 'y')
    @test b.quit && b.result == "1 + 1"

    # Every block can be copied, whole across blank lines; only Julia goes to the prompt.
    pb = DocBrowser.PageBuilder(60)
    DocBrowser.add_markdown!(pb, Markdown.parse("""
        ```toml
        [deps]

        Foo = "1"
        ```

        ```jldoctest
        julia> 1 + 1
        2

        julia> 2 + 2
        4
        ```
        """), Main, b.cat)
    codes = [s.target for s in pb.spots if s.target isa DocBrowser.CodeTarget]
    @test codes == [DocBrowser.CodeTarget("[deps]\n\nFoo = \"1\"", false), DocBrowser.CodeTarget("1 + 1\n2 + 2", true)]
    @test all(DocBrowser.is_code_line, pb.lines[1:3])
    # A file named in code, in lower case or in a path is not taken for a package.
    pb = DocBrowser.PageBuilder(60)
    DocBrowser.add_markdown!(pb, Markdown.parse("""
        ```
        \$ julia Script.jl
        ```

        Run `julia script.jl`, or src/Foo.jl, with NotAPackageXyz.jl.
        """), Main, b.cat)
    @test [s.target for s in pb.spots if s.target isa DocBrowser.URLTarget] == [DocBrowser.web_search("NotAPackageXyz")]
    # y on code that is not Julia says so, and stays.
    path = tempname() * ".md"
    write(path, "# Settings\n\n```toml\nx = 1\n```\n")
    b = test_browser()
    DocBrowser.follow!(b, DocBrowser.ManualTarget(path, ""))
    frame(b)
    p = DocBrowser.page(b, DocBrowser.current_key(b), DocBrowser.doc_width(b))
    b.focus = :doc
    b.doc_line = findfirst(l -> occursin("x = 1", String(l)), p.lines)
    @test !occursin("y send", strip_ansi(frame(b)[end]))
    press!(b, 'y')
    @test !b.quit && occursin("Only Julia code", b.status)
end

@testset "the manual" begin
    mktempdir() do dir
        mkpath(joinpath(dir, "manual"))
        write(joinpath(dir, "pages.toml"), """
            manual = ["manual/intro.md", "manual/missing.md", "manual/more.md"]
            base = []
            [[devdocs]]
            title = "Internals"
            pages = ["manual/more.md"]
            """)
        filler = "A paragraph, so that the page is longer than the screen.\n\n"^30
        write(joinpath(dir, "manual", "intro.md"), """
            # [Introduction](@id man-intro)

            ```@meta
            CurrentModule = Base
            ```

            See [the details](@ref man-details), [More](@ref), [a slug](@ref Second-part),
            [another page](more.md) and [`sum`](@ref). This is ```inline``` code. Pkg's
            [environments](https://pkgdocs.julialang.org/v1/environments/) are installed too.

            ```@docs; canonical=false
            sum
            ```

            ```@example
            1 + 1
            ```

            $(filler)
            ## [Details](@id man-details)

            $(filler)
            Second part
            -----------

            $(filler)
            """)
        write(joinpath(dir, "manual", "more.md"), "# More\n\nText.\n")
        cat = Catalog()
        all_pages = DocBrowser.manual_pages(dir)
        # The standard libraries' own pages come too, by the name of the library.
        stdlibs = filter(p -> p.role === :stdlibdocs, all_pages)
        @test any(p -> p.title == "Profile", stdlibs) && issorted(stdlibs, by=p -> lowercase(p.title))
        # Pkg's manual has a section of its own, in the order of its documentation build.
        pkg = filter(p -> p.role === :pkgdocs, all_pages)
        @test pkg[1].title == "Introduction" && DocBrowser.page_name(pkg[1]) == "Pkg"
        @test any(p -> p.title == "Managing Packages", pkg) && !any(p -> isdigit(p.title[1]), pkg)
        @test !any(p -> p.title == "Pkg", stdlibs)
        t = DocBrowser.pkgdocs_target("https://pkgdocs.julialang.org/dev/creating-packages/#adding-tests-to-packages")
        @test endswith(t.path, "creating-packages.md") && DocBrowser.anchor_heading(cat, t.path, t.anchor) > 0
        @test endswith(DocBrowser.pkgdocs_target("https://pkgdocs.julialang.org/v1/").path, "index.md")
        @test DocBrowser.pkgdocs_target("https://pkgdocs.julialang.org/v1/no-such-page/") === nothing
        cat.manual = filter(p -> !(p.role in (:stdlibdocs, :pkgdocs)), all_pages)
        cat.anchors = nothing
        # Pages that are listed but not installed are left out.
        @test [p.title for p in cat.manual] == ["Introduction", "More", "More"]
        @test [p.role for p in cat.manual] == [:manual, :manual, :devdocs]
        @test cat.manual[3].group == "Internals"
        intro = cat.manual[1].path
        hs = DocBrowser.page_headings(cat, intro)
        @test [(h.level, h.text, h.id) for h in hs] ==
            [(1, "Introduction", "man-intro"), (2, "Details", "man-details"), (2, "Second part", "")]
        @test DocBrowser.anchor_heading(cat, intro, "man-details") == 2
        @test DocBrowser.anchor_heading(cat, intro, "Second-part") == 3
        # Documenter syntax is made plain, and links to headings and pages lead there.
        p = DocBrowser.manual_page(cat, intro, 80)
        text = join(String.(p.lines), '\n')
        @test !occursin("@meta", text) && !occursin("@docs", text) && !occursin("@id", text)
        @test occursin("1 + 1", text) && length(p.headings) == 3
        targets = [s.target for s in p.spots]
        @test DocBrowser.ManualTarget(intro, "man-details") in targets
        @test DocBrowser.ManualTarget(intro, "Second-part") in targets
        @test DocBrowser.ManualTarget(cat.manual[2].path, "") in targets
        @test count(==(NameTarget(Base, :sum)), targets) == 2 # the link and the `@docs` entry
        @test any(t -> t isa DocBrowser.ManualTarget && endswith(t.path, joinpath("Pkg", "docs", "src", "environments.md")), targets)
        @test !any(t -> t isa DocBrowser.URLTarget && startswith(t.url, "@"), targets)
        # In the browser: the sidebar lists the pages, and the names pane their headings.
        b = test_browser()
        b.cat = cat
        push!(b.expanded, :manual)
        DocBrowser.refresh_side!(b)
        i = findfirst(r -> r.page !== nothing && r.page.path == intro, b.side_rows)
        b.side.cursor = i - 1
        DocBrowser.move!(b, :side, 1)
        @test DocBrowser.current_key(b) == DocBrowser.ManualTarget(intro, "")
        @test [r.kind for r in b.name_rows] == [:about, :heading, :heading]
        frame(b)
        @test occursin("2 sections", String(DocBrowser.pane_title(b, :names, 1, 40)))
        b.focus = :names
        press!(b, :down)
        shown = DocBrowser.page(b, DocBrowser.current_key(b), DocBrowser.doc_width(b))
        @test b.doc_scroll == shown.headings[2] - 1
        # Following a link opens the page at its heading, and picks the heading.
        DocBrowser.follow!(b, DocBrowser.ManualTarget(intro, "Second-part"))
        frame(b)
        @test b.doc_scroll == shown.headings[3] - 1
        @test DocBrowser.name_row(b).count == 3
        # A package's own manual page is linked from its module page, and opens on its own.
        page = DocBrowser.module_page(cat, Markdown, 80)
        t = findfirst(s -> s.target isa DocBrowser.ManualTarget, page.spots)
        @test t !== nothing
        DocBrowser.follow!(b, page.spots[t].target)
        @test b.override isa DocBrowser.ManualTarget
    end
    @test DocBrowser.slugify("Noteworthy differences from C/C++") == "Noteworthy-differences-from-C/C"
    # Links to Markdown files, with or without an anchor, and with `#` in the path.
    @test DocBrowser.manual_target("file:///a/README.md") == DocBrowser.ManualTarget("/a/README.md", "")
    @test DocBrowser.manual_target("file:///opt/c#/x.md#Top") == DocBrowser.ManualTarget("/opt/c#/x.md", "Top")
    @test DocBrowser.manual_target("file:///a/b.txt") === nothing
end

@testset "the nearest manual" begin
    refs = DocBrowser.manual_refs()
    @test first(refs) == DocBrowser.julia_ref() && last(refs) == "master"
    dir = DocBrowser.manual_dir()
    # Only a Julia without the manual installed goes online for it.
    if DocBrowser.installed_manual_dir() === nothing
        @test dir == DocBrowser.downloaded_manual_dir()
        # A commit that is not on GitHub falls back to the next place.
        @test first(DocBrowser.find_manual_ref(["0"^40, "master"])) == "master"
        page = joinpath(dir, "manual", "variables.md")
        cat = Catalog()
        text(p) = join(map(l -> strip(String(l)), p.lines), ' ')
        @test !occursin("not on GitHub", text(DocBrowser.manual_page(cat, page, 60)))
        write(joinpath(dir, "source.txt"), "master")
        try
            p = DocBrowser.manual_page(cat, page, 60)
            @test occursin("which is not on GitHub, so this page is from the master branch.", text(p))
        finally
            rm(joinpath(dir, "source.txt"))
        end
    end
end

@testset "the state of the manual download" begin
    b = Browser(fake_terminal(""))
    manual = b.cat.manual
    b.cat.manual = filter(p -> p.role !== :manual, manual)
    DocBrowser.MANUAL_ERROR[] = "RequestError: Could not resolve host"
    try
        DocBrowser.refresh_side!(b)
        @test any(l -> occursin("Manual failed", l), strip_ansi.(frame(b)))
        p = DocBrowser.section_page(b.cat, :manual, 80)
        @test occursin("could not be downloaded: RequestError", join(String.(p.lines), ' '))
        retry = only(s for s in p.spots if s.target == DocBrowser.ToggleTarget(:download))
        # Trying again clears the error, and once it is done the manual is listed.
        DocBrowser.follow!(b, retry.target)
        @test DocBrowser.manual_status() in (:downloading, :none)
        # A browser opened while it downloads gets the manual too.
        b2 = Browser(fake_terminal(""))
        b2.cat.manual = filter(p -> p.role !== :manual, manual)
        DocBrowser.download_manual!(b2)
        wait(DocBrowser.MANUAL_DOWNLOAD[])
        @test DocBrowser.manual_status() === :none
        @test any(p -> p.role === :manual, b.cat.manual)
        @test any(p -> p.role === :manual, b2.cat.manual)
        @test !any(l -> occursin(r"Manual (failed|loading)", l), strip_ansi.(frame(b)))
    finally
        DocBrowser.MANUAL_ERROR[] = DocBrowser.MANUAL_DOWNLOAD[] = nothing
        b.cat.manual = manual
    end
end

@testset "package manuals" begin
    mktempdir() do dir
        pkg = joinpath(dir, "DocsFixture")
        mkpath(joinpath(pkg, "src")); mkpath(joinpath(pkg, "docs", "src", "man"))
        write(joinpath(pkg, "Project.toml"), "name = \"DocsFixture\"\nuuid = \"5f0c6a0e-5f2b-4a4b-9d39-2f7cbbd3a6c1\"\n")
        write(joinpath(pkg, "src", "DocsFixture.jl"), """
            module DocsFixture
            export shout, Loud
            "Says it loudly."
            shout(x) = uppercase(x)
            "A loud thing."
            struct Loud end
            "Not exported."
            whisper(x) = lowercase(x)
            end
            """)
        write(joinpath(pkg, "docs", "make.jl"), """
            using Documenter, Literate, DocsFixture
            Literate.markdown("tutorial.jl", "src")
            const PAGES = Any["Home" => "index.md", "Guide" => ["man/api.md", "Tutorial" => "tutorial.md"]]
            makedocs(; sitename = "DocsFixture", pages = PAGES)
            """)
        write(joinpath(pkg, "docs", "src", "index.md"), "# DocsFixture\n\nSee [the API](man/api.md).\n")
        write(joinpath(pkg, "docs", "src", "man", "api.md"), """
            # API

            ```@autodocs
            Modules = [DocsFixture]
            Order = [:type, :function]
            Private = false
            ```
            """)
        push!(LOAD_PATH, dir)
        try
            M = Base.require(Main, :DocsFixture)
            cat = Catalog()
            docs = DocBrowser.package_docs(cat, M)
            # The pages are in the order of the build, with the titles it gives them.
            @test [(p.title, p.group) for p in docs.pages] == [("Home", ""), ("API", "Guide")]
            @test docs.missing == ["tutorial.md"] && docs.generator == "Literate"
            @test occursin("written by Literate", DocBrowser.docs_gap(docs))
            # The notice links to the online docs when they are known.
            pb = DocBrowser.PageBuilder(60)
            DocBrowser.gap_notice!(pb, docs, "https://example.org/docs/")
            @test only(s.target for s in pb.spots) == DocBrowser.URLTarget("https://example.org/docs/")
            @test occursin("The online docs should have all of it.", join(map(l -> strip(String(l)), pb.lines), ' '))
            @test DocBrowser.autodocs_names("Modules = [DocsFixture]", M, cat) == ["Loud", "shout", "whisper"]
            text(p) = join(map(l -> strip(String(l)), p.lines), ' ')
            api = DocBrowser.manual_page(cat, docs.pages[2].path, 80)
            @test occursin(r"• +Loud +• +shout", text(api)) && !occursin("whisper", text(api))
            @test occursin("the DocsFixture manual", text(api)) && occursin("Missing here: tutorial.md", text(api))
            @test NameTarget(M, :shout) in [s.target for s in api.spots]
            @test occursin("2 pages", text(module_page(cat, M, 80)))
            # In plain text, the manual's pages have addresses that `lookup` and `find_docs` know.
            hb = Browser(fake_terminal(""), cat)
            DocBrowser.HEADLESS[] = hb
            DocBrowser.PACKAGE_MANUALS[] = nothing
            try
                pm = only(m for m in DocBrowser.package_manuals(hb) if m.name == "DocsFixture")
                @test pm.refs == ["DocsFixture/index", "DocsFixture/man/api"]
                @test occursin("DocsFixture/man/api  API", DocBrowser.lookup("DocsFixture/"))
                api_page = DocBrowser.lookup("DocsFixture/man/api")
                @test startswith(api_page, "# DocsFixture/man/api\nPath: $(docs.pages[2].path)\n")
                @test occursin("DocsFixture/man/api  manual of DocsFixture: API", DocBrowser.find_docs("api"))
            finally
                DocBrowser.HEADLESS[] = nothing
                DocBrowser.PACKAGE_MANUALS[] = nothing
            end
            # The names pane lists the pages before the names, and picking one shows it.
            b = Browser(fake_terminal(""), cat)
            DocBrowser.show_module!(b, M)
            i = findfirst(r -> r.kind === :pkgpage, b.name_rows)
            @test b.name_rows[i - 1].group === :manual && count(r -> r.kind === :pkgpage, b.name_rows) == 2
            b.names.cursor = i + 1
            @test DocBrowser.current_key(b) == DocBrowser.ManualTarget(docs.pages[2].path, "")
            @test any(l -> occursin("API", l), strip_ansi.(frame(b)))
        finally
            filter!(!=(dir), LOAD_PATH)
        end
    end
    # A build script with no literal list of pages, and a directory other than `src`.
    @test DocBrowser.doc_page_list("makedocs(pages = make_pages())") === nothing
    # Lists built with `joinpath`, as Makie's are, plain, broadcast over names, or splatted.
    @test DocBrowser.doc_page_list("""
        pages = ["Home" => "index.md",
                 "Blocks" => joinpath.("reference", "blocks", ["axis.md", "label.md"]),
                 "Explanations" => [joinpath.("explanations", ["a.md"])..., "API" => joinpath("ref", "api.md")]]
        """) == [("index.md", "Home", ""), ("reference/blocks/axis.md", "", "Blocks"),
                 ("reference/blocks/label.md", "", "Blocks"), ("explanations/a.md", "", "Explanations"),
                 ("ref/api.md", "API", "Explanations")]
    # The tree hash of a directory, from GitHub's listing of its parent, for a downloaded manual.
    listing = """[{"name":"CairoMakie","path":"CairoMakie","sha":"$('a'^40)","type":"dir","_links":{"self":"x"}},
                  {"name":"GLMakie","path":"GLMakie","sha":"$('b'^40)","type":"dir","_links":{"self":"y"}}]"""
    @test DocBrowser.entry_sha(listing, "GLMakie") == 'b'^40 && DocBrowser.entry_sha(listing, "Makie") === nothing
    mktempdir() do dir
        mkpath(joinpath(dir, "docs", "source"))
        write(joinpath(dir, "docs", "make.jl"), "makedocs(source = \"source\", pages = [\"a.md\"])")
        write(joinpath(dir, "docs", "source", "a.md"), "# A\n")
        docs = DocBrowser.package_docs(dir)
        @test [p.title for p in docs.pages] == ["A"] && DocBrowser.docs_gap(docs) === nothing
    end
end

@testset "the sidebar: a row per library" begin
    b = Browser(fake_terminal(""))
    union!(b.expanded, (:basedocs, :stdlibdocs, :indirect))
    DocBrowser.refresh_side!(b)
    rows = b.side_rows
    lib(r) = r.pkg === nothing ? nothing : r.pkg.mod
    # Core and Base are in Base, and Main is last, on its own.
    @test [lib(r) for r in rows if r.role === :basedocs && r.pkg !== nothing] == [Base, Core]
    @test lib(rows[end]) === Main && rows[end].role === :main
    # A loaded standard library is one row of Standard library, and not an indirect dependency.
    i = findfirst(r -> lib(r) === Markdown, rows)
    @test rows[i].role === :stdlibdocs
    @test !any(r -> r.role === :indirect && lib(r) === Markdown, rows)
    @test !any(r -> r.page !== nothing && r.page.title == "Markdown", rows)
    # Its names pane lists its manual, then its names.
    b.side.cursor = i
    DocBrowser.sync_side!(b)
    @test b.mod === Markdown && b.name_rows[2].group === :manual
    @test any(r -> r.kind === :entry, b.name_rows)
    # Opening its manual page picks the page among them.
    page = DocBrowser.stdlib_page("Markdown")
    DocBrowser.open_manual!(b, page, 0)
    @test DocBrowser.side_row(b).pkg.mod === Markdown
    @test DocBrowser.current_key(b) == DocBrowser.ManualTarget(normpath(page), "")
end

@testset "the headings of a page line up with what it shows" begin
    mktempdir() do dir
        path = joinpath(dir, "page.md")
        write(path, """
            # A title

            ## A heading long enough to wrap onto several lines of a narrow pane, and then some more

            !!! note
                ## A heading in an admonition

            ```julia
            x = 1
              ```
            ## Not a heading, still in the code
            ```

            ### ``\\LaTeX``

            Underlined
            ----------

            [Words](@ref "Underlined") and [`sum`](@ref).
            """)
        cat = Catalog()
        cat.manual = [DocBrowser.ManualPage(path, "A title", :manual, "")]
        hs = DocBrowser.page_headings(cat, path)
        @test [h.text for h in hs] == ["A title", "A heading long enough to wrap onto several lines of a narrow pane, and then some more",
                                      "A heading in an admonition", "\\LaTeX", "Underlined"]
        for width in (24, 40, 80)
            @test length(DocBrowser.manual_page(cat, path, width).headings) == length(hs)
        end
        # A link in words names a heading, and one in code a docstring.
        targets = [s.target for s in DocBrowser.manual_page(cat, path, 80).spots]
        @test DocBrowser.ManualTarget(path, "Underlined") in targets
        @test NameTarget(Base, :sum) in targets
        b = test_browser()
        b.cat = cat
        DocBrowser.follow!(b, DocBrowser.ManualTarget(path, "Underlined"))
        @test DocBrowser.name_row(b).kind === :heading
        # Left from a page's headings goes back to the sidebar, even inside a submodule.
        b.focus = :names
        b.mod = Base.Iterators
        press!(b, :left)
        @test b.focus === :side && b.mod === Base.Iterators
        # Unfolding and folding everything while a page's headings are listed keeps the panes in step.
        b.focus = :names
        press!(b, 'a', 'a')
        @test frame(b) isa Vector
    end
end

@testset "searching the manual, and the sidebar" begin
    b = test_browser()
    # Only the hit picked is highlighted, among hits from many pages.
    press!(b, '/', "point"...)
    selected(i) = any(a -> a.value === :REPL_DocBrowser_selected,
                      Base.annotations(DocBrowser.list_line(b, :names, i, 1, 40, 2)))
    hits = findall(r -> r.kind === :hit, b.name_rows)
    @test length(hits) > 3
    @test all(hits) do i
        b.names.cursor = i
        findall(selected, eachindex(b.name_rows)) == [i]
    end
    press!(b, :escape)
    # A standard library's page is found by its name, whether an earlier test loaded it or not.
    press!(b, '/', "Profile"...)
    @test isempty(b.manual_hits[1].heading) && DocBrowser.manual_title(b.cat, b.manual_hits[1].path) == "Profile"
    h = findfirst(r -> r.kind === :header && r.group === :manual_hits, b.name_rows)
    @test h !== nothing && b.name_rows[h+1].kind === :hit
    # Picking a hit shows that page, and Enter opens it in the sidebar.
    b.names.cursor = h + 1
    DocBrowser.move!(b, :names, 0)
    @test DocBrowser.current_key(b) == DocBrowser.ManualTarget(b.manual_hits[1].path, "")
    frame(b)
    @test occursin("manual", String(DocBrowser.pane_title(b, :doc, 1, 60)))
    profile = b.manual_hits[1].path
    press!(b, :enter)
    @test b.query === nothing && DocBrowser.current_key(b) == DocBrowser.ManualTarget(profile, "")
    # Pkg's manual is found by Pkg's name, and its pages say where they are from. What follows
    # is how it is shown while Pkg is not loaded, so Pkg is left out if something loaded it.
    filter!(p -> p.id.name != "Pkg", b.cat.pkgs)
    DocBrowser.refresh_side!(b)
    press!(b, '/', "Pkg"...)
    @test DocBrowser.page_name(b.cat.manual[DocBrowser.manual_page_of(b.cat, b.manual_hits[1].path)]) == "Pkg"
    h = findfirst(r -> r.kind === :hit, b.name_rows)
    plain(rows) = [replace(l, r"\e\[[0-9;]*m" => "") for l in rows]
    # Names come first when an earlier test loaded Pkg, so look at the hit's row itself.
    @test occursin(r"Introduction +Pkg", plain([String(DocBrowser.list_line(b, :names, h, 1, 40, 2))])[1])
    b.names.cursor = h
    press!(b, :enter)
    @test DocBrowser.side_page(b).role === :pkgdocs
    # Pkg is one row of the standard libraries, in its place among them, and the names pane
    # lists its pages, the one opened unfolded to its headings.
    rows = b.side_rows
    i = b.side.cursor
    prev = rows[i-1].page === nothing ? rows[i-1].pkg.id.name : rows[i-1].page.title # a loaded library is a package row
    @test rows[i].role === :pkgdocs && rows[i-1].role === :stdlibdocs && lowercase(prev) < "pkg"
    screen = plain(frame(b))
    @test any(l -> startswith(l, "   Pkg "), screen) && any(l -> occursin("│ Pkg  $(length(DocBrowser.pkg_pages(b))) pages", l), screen)
    pages = DocBrowser.pkg_pages(b)
    @test count(r -> r.kind === :page, b.name_rows) == length(pages)
    @test any(r -> r.kind === :heading && r.hit.path == pages[1].path, b.name_rows)
    # Picking another page shows it and unfolds it; its headings scroll to their place.
    j = findfirst(r -> r.kind === :page && r.hit.path == pages[3].path, b.name_rows)
    b.focus = :names
    b.names.cursor = j
    DocBrowser.move!(b, :names, 0)
    press!(b, :enter)
    @test DocBrowser.current_key(b) == DocBrowser.ManualTarget(pages[3].path, "")
    k = findfirst(r -> r.kind === :heading && r.hit.path == pages[3].path, b.name_rows)
    DocBrowser.move!(b, :names, k - j)
    @test DocBrowser.current_key(b) == DocBrowser.ManualTarget(pages[3].path, "") && b.doc_scroll > 0
    @test occursin("Pkg › " * pages[3].title, String(DocBrowser.header_bar(b)))
    # A link to a heading of another page opens Pkg there.
    t = DocBrowser.pkgdocs_target("https://pkgdocs.julialang.org/dev/creating-packages/#adding-tests-to-packages")
    DocBrowser.follow!(b, t)
    r = DocBrowser.name_row(b)
    @test r.kind === :heading && r.hit.path == t.path && DocBrowser.current_key(b) == DocBrowser.ManualTarget(t.path, "")
    DocBrowser.follow!(b, DocBrowser.SectionTarget(:stdlibdocs))
    p = DocBrowser.page(b, DocBrowser.current_key(b), DocBrowser.doc_width(b))
    @test DocBrowser.ManualTarget(pages[1].path, "") in [s.target for s in p.spots]
    # A search for an exact name lists the names first, so Enter opens it.
    press!(b, '/', "sort"...)
    @test DocBrowser.name_row(b).kind === :entry && DocBrowser.name_row(b).entry.name === :sort
    @test any(r -> r.kind === :hit, b.name_rows)
    press!(b, :escape)
    # Indirect dependencies are left out of searches until asked for.
    b.cat.bymod[Fixture] = DocBrowser.PkgEntry(Fixture, Base.PkgId(Base.UUID(UInt128(3)), "Fixture"),
                                               nothing, :indirect, String[], nothing)
    press!(b, '/', "documented"...)
    @test b.hidden > 0 && !any(e -> e.mod === Fixture, b.results)
    @test b.name_rows[end].kind === :more
    press!(b, KeyEvent('a', DocBrowser.CTRL))
    @test b.hidden == 0 && any(e -> e.mod === Fixture, b.results)
    press!(b, KeyEvent('a', DocBrowser.CTRL))
    b.names.cursor = length(b.name_rows)
    press!(b, :enter) # while typing, on the row that says what was left out
    @test b.hidden == 0
    # Outside the search field, Ctrl-A and Enter on that row also leave them out and bring them in.
    b.typing = false
    b.focus = :names
    press!(b, KeyEvent('a', DocBrowser.CTRL))
    @test b.hidden > 0
    b.names.cursor = length(b.name_rows)
    press!(b, :enter)
    @test b.hidden == 0 && b.query !== nothing
    press!(b, KeyEvent('a', DocBrowser.CTRL))
    press!(b, :escape)
    delete!(b.cat.bymod, Fixture)
    # A hit's source is its page, at its heading; Enter opens it, and its links say where they go.
    press!(b, '/', "Wall-time"...)
    b.typing = false
    i = findfirst(r -> r.kind === :hit, b.name_rows)
    src = DocBrowser.hit_subject(b, (:names, i))
    @test src isa DocBrowser.SourceTarget && src.line > 1
    b.names.cursor = i
    press!(b, :enter)
    @test b.query === nothing && DocBrowser.side_page(b) !== nothing
    @test DocBrowser.hit_subject(b, (:names, 1)) == DocBrowser.SourceTarget(DocBrowser.side_page(b).path, 1)
    t = DocBrowser.ManualTarget(DocBrowser.side_page(b).path, "")
    @test occursin("the manual", DocBrowser.describe_target(b, DocBrowser.page(b, t, 80), t))
    # The section in the breadcrumbs leads to its overview.
    frame(b)
    h = only(h for h in b.hits if h.action isa Tuple && first(h.action) === :section)
    handle!(b, MouseEvent(:press, 1, h.row, first(h.cols), 0))
    @test DocBrowser.current_key(b) isa DocBrowser.SectionTarget
    # Headings are found as well, and text search looks in the sections.
    hits = DocBrowser.search_manual(b.cat, "performance tips")
    @test any(h -> DocBrowser.hit_title(b.cat, h) == "Performance Tips", hits)
    @test !isempty(DocBrowser.search_manual(b.cat, "type-stable"; text=true))
    # The sidebar has the documentation, then the docstrings of loaded code, and indirect
    # dependencies are inside the dependencies.
    roles = [r.role for r in b.side_rows if DocBrowser.is_header(r)]
    @test roles[1] === :docs && :code in roles
    @test findfirst(==(:code), roles) > findfirst(==(:devdocs), roles)
end

@testset "the start page" begin
    # Opening the browser, which picks an order for the tips, leaves the random numbers alone.
    Random.seed!(1); x = rand()
    Random.seed!(1); test_browser(); @test rand() == x
    b = test_browser()
    # A fresh browser opens on the start page, whose sections the names pane lists.
    @test DocBrowser.current_key(b) === :start
    @test [r.kind for r in b.name_rows] == [:about; fill(:heading, length(DocBrowser.START_SECTIONS))]
    p = DocBrowser.page(b, :start, DocBrowser.doc_width(b))
    text = join(String.(p.lines), '\n')
    @test occursin(string(VERSION), text)
    @test length(p.headings) == length(DocBrowser.START_SECTIONS)
    targets = [s.target for s in p.spots]
    @test any(t -> t isa DocBrowser.ManualTarget && endswith(t.path, "getting-started.md"), targets)
    @test any(t -> t isa DocBrowser.ManualTarget && endswith(t.path, "NEWS.md") ||
                   t isa DocBrowser.URLTarget && occursin("NEWS", t.url), targets)
    # Picking a section scrolls to it, and the header and panes say where we are.
    b.focus = :names
    press!(b, :down)
    frame(b)
    @test occursin("Start", String(DocBrowser.header_bar(b)))
    @test occursin("$(length(DocBrowser.START_SECTIONS)) sections", String(DocBrowser.pane_title(b, :names, 1, 40)))
    # The last section is too near the end to scroll to, so a mark beside it shows the move.
    press!(b, :end)
    w = DocBrowser.doc_width(b)
    p = DocBrowser.page(b, :start, w)
    @test b.mark == p.headings[end] && b.doc_scroll < b.mark - 1
    @test startswith(String(DocBrowser.draw_doc(b, 1, w)[b.mark - b.doc_scroll]), "▶")
    press!(b, :up)
    @test b.mark == p.headings[end-1]
    # Every tip in the file is well formed, including those for other systems.
    for t in Base.parsed_toml(joinpath(pkgdir(DocBrowser), "src", "tips.toml"))["tip"]
        @test issubset(keys(t), ("text", "docs", "page", "heading", "os", "julia")) && t["text"] isa String
        @test count(k -> haskey(t, k), ("docs", "page", "heading")) in (0, 3)
        @test all(in(keys(DocBrowser.SYSTEMS)), get(t, "os", String[]))
    end
    # Every tip fits its box and wraps between words, and the docs that it links to are installed.
    for (i, tip) in enumerate(DocBrowser.TIPS)
        lines = String.(DocBrowser.start_page(b.cat, 50, i).lines)
        top = findfirst(l -> occursin("Did you know?", l), lines)
        bottom = findnext(l -> occursin("╰", l), lines, top)
        @test all(l -> textwidth(l) == 48 && endswith(l, "│") && !occursin(r"^  │   \S", l), lines[top+1:bottom-1])
        @test occursin(replace(split(tip[1])[end], '`' => ""), join(lines, ' '))
        link = DocBrowser.tip_link(tip)
        @test (link === nothing) == (tip[2] === nothing)
        # some of the headings are newer than older versions' docs
        link === nothing || VERSION < v"1.14" || @test DocBrowser.anchor_heading(b.cat, link.path, link.anchor) > 0
    end
    # The box keeps its size from tip to tip, and its links their place.
    for width in (50, 100)
        boxes = map(eachindex(DocBrowser.TIPS)) do i
            p = DocBrowser.start_page(b.cat, width, i, length(DocBrowser.TIPS))
            next = findfirst(s -> s.target == DocBrowser.ToggleTarget(:tip), p.spots)
            (length(p.lines), p.spots[next].line)
        end
        @test allequal(boxes)
    end
    # Each browser shows the tips in its own order. `t`, `T` and the links in the box step
    # through them, and they come round again.
    @test sort(b.tips) == eachindex(DocBrowser.TIPS) && b.tip == 1
    b.focus = :doc
    tip_text() = join(String.(DocBrowser.page(b, :start, DocBrowser.doc_width(b)).lines), '\n')
    before = tip_text()
    press!(b, 't')
    @test b.tip == 2 && tip_text() != before && occursin("2 of", tip_text())
    press!(b, 'T')
    @test b.tip == 1 && tip_text() == before
    p = DocBrowser.page(b, :start, DocBrowser.doc_width(b))
    back = findfirst(s -> s.target == DocBrowser.ToggleTarget(:tip_back), p.spots)
    @test occursin("previous", String(collect(String(p.lines[p.spots[back].line]))[p.spots[back].cols]))
    DocBrowser.follow!(b, p.spots[back].target)
    @test b.tip == length(DocBrowser.TIPS)
    DocBrowser.follow!(b, DocBrowser.ToggleTarget(:tip))
    @test b.tip == 1 && tip_text() == before
    DocBrowser.follow!(b, NameTarget(Base, :sum))
    press!(b, 't'); @test b.tip == 1 && occursin("start page", b.status)
end

@testset "links to places" begin
    cat = Catalog()
    place(text) = DocBrowser.place_target(text, cat)
    # Every page of the manual has a place that leads back to it.
    for p in cat.manual
        ref = DocBrowser.page_ref(p.path)
        @test ref !== nothing && place("docs: " * ref) == DocBrowser.ManualTarget(p.path, "")
    end
    # A heading, by its `@id` or by its text, and the same place in the online docs.
    tips = DocBrowser.place_file("manual/performance-tips")
    @test place("docs: manual/performance-tips#man-code-warntype") == DocBrowser.ManualTarget(tips, "man-code-warntype")
    @test place("https://docs.julialang.org/en/v1.12/manual/performance-tips/#man-code-warntype") ==
        DocBrowser.ManualTarget(tips, "man-code-warntype")
    env = place("docs: stdlib/Pkg/environments#Temporary-environments")
    @test env isa DocBrowser.ManualTarget && DocBrowser.anchor_heading(cat, env.path, env.anchor) > 0
    @test place("https://pkgdocs.julialang.org/v1/environments/") == DocBrowser.ManualTarget(env.path, "")
    # Names, and the docstrings that the online docs give by name.
    @test place("docs: Base.Iterators") == ModuleTarget(Base.Iterators)
    @test place("https://docs.julialang.org/en/v1/base/collections/#Base.sum-Tuple{Any}") isa NameTarget
    # Text that names no place.
    for text in ("sum", "docs: manual/../../etc/passwd", "docs: manual/no-such-page", "docs: Base.nosuchname",
                 "https://example.com/manual/performance-tips/")
        @test place(text) === nothing
    end
    # `c`, or the link above the page, copies the place shown, at the section scrolled to.
    b = test_browser()
    DocBrowser.open_manual!(b, tips, DocBrowser.anchor_heading(cat, tips, "man-code-warntype"))
    frame(b)
    press!(b, 'c')
    @test startswith(COPIED[end], "help?> docs: manual/performance-tips#")
    @test place(chopprefix(COPIED[end], "help?> ")) == DocBrowser.ManualTarget(tips, "man-code-warntype")
    DocBrowser.follow!(b, NameTarget(Base, :sum))
    frame(b)
    h = first(h for h in b.hits if h.action == (:copylink,))
    handle!(b, MouseEvent(:press, 1, h.row, first(h.cols), 0))
    @test COPIED[end] == "help?> docs: Base.sum" && occursin("Copied", b.status)
    DocBrowser.follow!(b, DocBrowser.SectionTarget(:docs))
    press!(b, 'c'); @test occursin("no link", b.status)
end

@testset "hover cards and history" begin
    b = test_browser()
    DocBrowser.follow!(b, NameTarget(Base, :sort!))
    frame(b)
    # Resting the pointer on a name shows a card with the start of its docstring.
    h = first(h for h in b.hits if h.action isa Tuple && first(h.action) === :names &&
              b.name_rows[h.action[2]].kind === :entry)
    handle!(b, MouseEvent(:move, 0, h.row, first(h.cols) + 1, 0))
    # Not straight away. The times are given, since a slow machine can take longer than the
    # delay to get from one line of this test to the next.
    rested = b.hover_since
    @test b.card === nothing && !DocBrowser.show_card!(b, rested + 0.01)
    @test DocBrowser.show_card!(b, rested + 1)
    entry = b.name_rows[h.action[2]].entry
    @test occursin(String(entry.name), String(b.card[1][1]))
    @test any(r -> occursin("╭", r), frame(b))
    # On the screen, the card shows by itself a moment after the pointer comes to rest.
    live = test_browser()
    DocBrowser.follow!(live, NameTarget(Base, :sort!))
    frame(live)
    live.live = true
    handle!(live, MouseEvent(:move, 0, h.row, first(h.cols) + 1, 0))
    @test timedwait(() -> live.card !== nothing, 60) === :ok
    live.live = false
    # Moving onto the card keeps it; right-click on it is its source; a click opens it.
    c = first(h for h in b.hits if h.action == (:card,))
    handle!(b, MouseEvent(:move, 0, c.row, first(c.cols) + 1, 0))
    @test b.card !== nothing && DocBrowser.hit_subject(b, (:card,)) == entry
    handle!(b, MouseEvent(:press, 1, c.row, first(c.cols) + 1, 0))
    frame(b)
    @test b.card === nothing && DocBrowser.current_key(b) == entry
    # Cards of modules and of the manual.
    @test occursin("module", String(DocBrowser.card_lines(b, ModuleTarget(Base.Iterators), 40)[1]))
    tips = findfirst(p -> endswith(p.path, "performance-tips.md"), b.cat.manual)
    if tips !== nothing
        t = DocBrowser.ManualTarget(b.cat.manual[tips].path, "")
        @test occursin("manual", String(DocBrowser.card_lines(b, t, 40)[1]))
    end
    # Tabbing to a link previews it too, below the link's line.
    DocBrowser.follow!(b, NameTarget(Base, :sort!))
    frame(b)
    press!(b, :tab)
    b.hover_since -= 1
    @test DocBrowser.show_card!(b) && b.card !== nothing
    rows = frame(b)
    top = findfirst(r -> occursin("╭", r), rows)
    @test top == b.hover_at[1] + 1
    press!(b, :tab) # the next link closes it, and its own card follows
    @test b.card === nothing && b.hover == (:spot, b.link)
    # Back says where it leads, then where it went, and selects the link that was followed.
    DocBrowser.follow!(b, NameTarget(Base, :sort!))
    b.link = 0
    frame(b)
    press!(b, :tab)
    followed = b.link
    press!(b, :enter)
    @test occursin("back to Base.sort!", DocBrowser.describe(b, (:back,)))
    press!(b, :backspace)
    @test b.status == "Back to Base.sort!" && b.link == followed
    @test occursin("forward to", DocBrowser.describe(b, (:forward,)))
    press!(b, ']')
    @test startswith(b.status, "Forward to")
end

@testset "edge cases" begin
    b = test_browser()
    doc_text(b) = join(String.(DocBrowser.page(b, DocBrowser.current_key(b), DocBrowser.doc_width(b)).lines), '\n')
    # Types with no definite number of fields still have pages.
    for T in (:Tuple, :NamedTuple, :NTuple)
        DocBrowser.follow!(b, NameTarget(Core, T))
        @test !occursin("Could not show", doc_text(b))
    end
    # The help leaves the page under it as it was.
    DocBrowser.follow!(b, NameTarget(Base, :sort!)); frame(b)
    b.doc_scroll = 3
    press!(b, '?'); press!(b, :escape)
    @test b.doc_scroll == 3
    # A link to a name in a folded group unfolds the group, not internal names.
    DocBrowser.show_module!(b, Fixture)
    push!(b.collapsed, :function)
    DocBrowser.show_module!(b, Fixture; entry=:documented)
    @test !b.internal && DocBrowser.name_row(b).entry.name === :documented
    # A long name can only be clicked inside its own pane.
    DocBrowser.show_module!(b, Base); frame(b)
    _, x, w = only(l for l in DocBrowser.layout(b) if l[1] === :names)
    i = argmax(i -> b.name_rows[i].entry === nothing ? 0 : length(String(b.name_rows[i].entry.name)), eachindex(b.name_rows))
    b.names.cursor = i; DocBrowser.reveal!(b.names, DocBrowser.content_rows(b)); frame(b)
    @test all(h -> !(h.action isa Tuple && first(h.action) === :names) || last(h.cols) <= x + w - 1, b.hits)
    # A click ends typing in the search field.
    press!(b, '/', 's')
    h = first(h for h in b.hits if h.action isa Tuple && first(h.action) === :side)
    handle!(b, MouseEvent(:press, 1, h.row, first(h.cols), 0)); frame(b)
    @test !b.typing
    # On a section heading, Shift-Tab does not move into the empty names pane.
    DocBrowser.close_search!(b)
    b.side.cursor = 2
    DocBrowser.move!(b, :side, 0)
    b.focus = :side
    press!(b, :backtab)
    @test b.focus === :side
    # A double-click past the end of a line selects nothing.
    @test DocBrowser.word_cols("abc", 4) === nothing
end

@testset "keys in the documentation" begin
    b = test_browser()
    DocBrowser.follow!(b, NameTarget(Base, :sort!))
    frame(b)
    @test b.focus === :doc
    press!(b, :pagedown); @test b.doc_scroll > 0
    press!(b, :pageup);   @test b.doc_scroll == 0
    press!(b, ' ');       @test b.doc_scroll > 0
    press!(b, :home);     @test b.doc_scroll == 0
    press!(b, :end);      @test b.doc_scroll > 0
    press!(b, 'g', 'j');  @test b.doc_scroll == 0 && b.doc_line == 2
    press!(b, 'k');       @test b.doc_line == 1
    press!(b, 'o');       @test occursin("web link", b.status)
    press!(b, :enter);    @test occursin("No link on this line", b.status)
    # The cursor moves down five rows before the page scrolls, which keeps five lines above it.
    press!(b, 'j', 'j', 'j', 'j', 'j'); @test b.doc_scroll == 0 && b.doc_line == 6
    press!(b, 'j');       @test b.doc_scroll == 1 && b.doc_line == 7
    press!(b, 'k');       @test b.doc_scroll == 0 && b.doc_line == 6
    # At the end of the page, where it cannot scroll, the cursor moves on to the last line.
    nlines = length(DocBrowser.page(b, DocBrowser.current_key(b), DocBrowser.doc_width(b)).lines)
    press!(b, 'G');       @test b.doc_line == nlines
    press!(b, 'k');       @test b.doc_line == nlines - 1 == b.doc_scroll + DocBrowser.content_rows(b) - 1
    press!(b, 'g');       @test b.doc_line == 1 && b.doc_scroll == 0
    # ⇥ puts the cursor on the link it picks, and the cursor picks a link on its line.
    press!(b, :tab);      line = b.doc_line; @test b.link > 0
    press!(b, 'j', 'k');  @test b.doc_line == line && b.link > 0
    press!(b, :backtab);  @test b.link > 0
    press!(b, :escape);   @test b.link == 0 && !b.quit
    # History with the keyboard: ⌫ [ ] and Alt with arrows or b and f.
    DocBrowser.follow!(b, NameTarget(Base, :sum))
    press!(b, KeyEvent(:left, DocBrowser.ALT))
    @test DocBrowser.current_key(b).name === :sort!
    press!(b, KeyEvent(:right, DocBrowser.ALT))
    @test DocBrowser.current_key(b).name === :sum
    press!(b, KeyEvent('b', DocBrowser.ALT), KeyEvent('f', DocBrowser.ALT))
    @test DocBrowser.current_key(b).name === :sum
    press!(b, ']');       @test occursin("Nothing to go forward", b.status)
    empty!(b.back)
    press!(b, '[');       @test occursin("Nothing to go back", b.status)
    # The help page scrolls, and any other key closes it.
    press!(b, '?');       @test b.help
    press!(b, :down, :pagedown, :up, ' ')
    @test b.help
    press!(b, 'z');       @test !b.help
    press!(b, :f1);       @test b.help
    press!(b, :escape);   @test !b.help
    press!(b, 'x');       @test :extended in DocBrowser.page_flags(b, DocBrowser.current_key(b)) ||
                                occursin("No extended help", b.status)
    # A web link opens with `o`, and `e` opens the source of the page.
    DocBrowser.follow!(b, NameTarget(Fixture, :documented))
    p = DocBrowser.page(b, DocBrowser.current_key(b), DocBrowser.doc_width(b))
    b.link = findfirst(s -> s.target isa DocBrowser.URLTarget, p.spots)
    press!(b, 'o');       @test OPENED[end] == "https://docs.julialang.org"
    b.link = 0
    press!(b, 'e');       @test endswith(EDITED[end][1], "runtests.jl")
    # Quitting.
    for k in ('q', KeyEvent('c', DocBrowser.CTRL), KeyEvent('d', DocBrowser.CTRL), :escape)
        b.quit = false
        press!(b, k)
        @test b.quit
    end
    # On a page that fits, ↓ moves the cursor.
    b = test_browser()
    DocBrowser.follow!(b, NameTarget(Fixture, :documented))
    frame(b)
    press!(b, 'j');       @test b.doc_scroll == 0 && b.doc_line == 2
end

@testset "keys while searching" begin
    b = test_browser()
    press!(b, '/', :backspace); @test b.typing && b.query == ""
    press!(b, 's', 'u', 'm')
    @test !isempty(b.results)
    # The documentation shows the result picked, and nothing when there is none to pick.
    @test DocBrowser.current_key(b) isa DocBrowser.NameEntry
    press!(b, KeyEvent('u', DocBrowser.CTRL)); @test b.query == ""
    @test DocBrowser.hint_key("^A") == KeyEvent('a', DocBrowser.CTRL)
    press!(b, 'z', 'q', 'x', 'j', 'v')
    press!(b, :enter);    @test b.status == "No matches"
    @test DocBrowser.current_key(b) === :none
    @test all(isempty ∘ strip ∘ String, DocBrowser.draw_doc(b, 1, 60))
    @test strip(String(DocBrowser.pane_title(b, :doc, 1, 60))) == ""
    press!(b, KeyEvent('u', DocBrowser.CTRL), 's', 'u', 'm')
    # How many names match depends on what earlier tests loaded.
    start = b.names.cursor
    press!(b, :down, KeyEvent('n', DocBrowser.CTRL)); @test b.names.cursor == start + 2
    press!(b, :up, KeyEvent('p', DocBrowser.CTRL));   @test b.names.cursor == start
    press!(b, :pagedown); @test b.names.cursor > start
    press!(b, :pageup, :pageup); @test b.names.cursor == 1
    press!(b, :tab);      @test !b.typing && b.query == "sum"
    press!(b, 'i');       @test b.internal && length(b.results) > 0
    press!(b, :escape);   @test b.query === nothing
    press!(b, '/', 'a', KeyEvent('g', DocBrowser.CTRL))
    @test b.query === nothing
    press!(b, KeyEvent('f', DocBrowser.CTRL), :right)
    @test b.query == "" && !b.typing
    handle!(b, PasteEvent("  sort \n "))
    @test b.query == "sort" && b.typing
    @test !handle!(b, PasteEvent("   "))
    # The query edits as a readline field: the cursor moves, words go with ^W and
    # Alt-Backspace, and ^Y puts back what went. → moves the cursor, and only past the end
    # goes on to the results.
    ctrl(c) = KeyEvent(c, DocBrowser.CTRL)
    press!(b, ctrl('u'), 'B', 'a', 's', 'e', '.', 's', 'r', 't')
    press!(b, :left, :left, 'o'); @test b.query == "Base.sort"
    @test occursin(" Base.so▏rt", String(DocBrowser.header_bar(b)))
    press!(b, :right);    @test b.typing
    handle!(b, PasteEvent("ed!")); @test b.query == "Base.sored!t"
    press!(b, KeyEvent(:end), KeyEvent(:backspace, DocBrowser.ALT)); @test b.query == "Base.sored!"
    press!(b, KeyEvent(:left, DocBrowser.ALT), ctrl('k')); @test b.query == "Base."
    press!(b, ctrl('y'), ctrl('y')); @test b.query == "Base.sored!sored!"
    press!(b, :home, KeyEvent(:delete), ctrl('e'), ctrl('w')); @test b.query == ""
    press!(b, 's', 'u', 'm', :right); @test !b.typing && b.query == "sum"
end

@testset "clicking and hovering everything" begin
    b = test_browser()
    DocBrowser.follow!(b, NameTarget(Fixture, :documented))
    frame(b)
    for h in copy(b.hits)
        # Every region says what clicking it does, or nothing, without failing.
        b.hover = h.action
        @test DocBrowser.footer_message(b) isa String
        handle!(b, MouseEvent(:move, 0, h.row, first(h.cols), 0))
        handle!(b, MouseEvent(:press, 1, h.row, first(h.cols), 0))
        handle!(b, MouseEvent(:release, 1, h.row, first(h.cols), 0))
        frame(b)
        b.quit = false
        b.help = false
    end
    # The scroll bar can be dragged.
    DocBrowser.follow!(b, NameTarget(Base, :sort!))
    frame(b)
    bar = findfirst(h -> first(h.action) === :scrollbar, b.hits)
    last_bar = findlast(h -> first(h.action) === :scrollbar, b.hits)
    handle!(b, MouseEvent(:drag, 1, b.hits[last_bar].row, first(b.hits[last_bar].cols), 0))
    @test b.doc_scroll > 0
    handle!(b, MouseEvent(:press, 1, b.hits[bar].row, first(b.hits[bar].cols), 0))
    @test b.doc_scroll == 0
    # The wheel scrolls the pane under the pointer, and nothing outside the panes.
    for (pane, x, w) in DocBrowser.layout(b)
        handle!(b, MouseEvent(:wheeldown, 0, 5, x + 1, 0))
        handle!(b, MouseEvent(:wheelup, 0, 5, x + 1, 0))
    end
    @test !handle!(b, MouseEvent(:wheeldown, 0, 1, 1, 0))
    @test !handle!(b, MouseEvent(:wheelside, 0, 5, 5, 0))
    # A click outside every region focuses the pane under it; elsewhere it closes help.
    b.help = true
    handle!(b, MouseEvent(:press, 1, b.height - 1, 3, 0))
    @test !b.help
    # The mouse's back and forward buttons.
    DocBrowser.follow!(b, NameTarget(Base, :sort!))
    DocBrowser.follow!(b, NameTarget(Base, :sum))
    handle!(b, MouseEvent(:press, 8, 5, 5, 0)); @test DocBrowser.current_key(b).name === :sort!
    handle!(b, MouseEvent(:press, 9, 5, 5, 0)); @test DocBrowser.current_key(b).name === :sum
    @test !handle!(b, MouseEvent(:press, 2, 5, 5, 0))
    # Double-clicking a package opens its names.
    b.focus = :side
    i = findfirst(r -> r.pkg !== nothing, b.side_rows)
    b.side.scroll = i - 1 # so that the row is on the screen
    frame(b)
    h = b.hits[findfirst(h -> h.action == (:side, i), b.hits)]
    handle!(b, MouseEvent(:press, 1, h.row, first(h.cols), 0))
    handle!(b, MouseEvent(:press, 1, h.row, first(h.cols), 0))
    @test b.focus === :names
end

@testset "following every kind of link" begin
    b = test_browser()
    DocBrowser.follow!(b, DocBrowser.URLTarget("https://example.org"))
    @test OPENED[end] == "https://example.org" && occursin("Opened", b.status)
    DocBrowser.follow!(b, DocBrowser.SourceTarget(@__FILE__, 3))
    @test EDITED[end] == (@__FILE__, 3)
    DocBrowser.follow!(b, DocBrowser.SourceTarget("/no/such/file.jl", 1))
    @test occursin("not found", b.status)
    DocBrowser.follow!(b, DocBrowser.SectionTarget(:basedocs))
    @test b.focus === :side && DocBrowser.current_key(b) == DocBrowser.SectionTarget(:basedocs)
    DocBrowser.follow!(b, NameTarget(Fixture, :Inner))
    @test b.mod === Fixture.Inner
    DocBrowser.follow!(b, NameTarget(Fixture, :helper))
    @test b.internal && DocBrowser.current_key(b).name === :helper
    # Failures while away from the screen are reported, not thrown.
    DocBrowser.URL_OPENER[] = url -> error("no browser")
    DocBrowser.follow!(b, DocBrowser.URLTarget("https://example.org"))
    @test occursin("Could not open", b.status)
    # An interrupt is not such a failure.
    DocBrowser.URL_OPENER[] = url -> throw(InterruptException())
    @test_throws InterruptException DocBrowser.follow!(b, DocBrowser.URLTarget("https://example.org"))
    DocBrowser.EDITOR[] = (f, l) -> error("no editor")
    DocBrowser.follow!(b, DocBrowser.SourceTarget(@__FILE__, 1))
    @test occursin("no editor", b.status)
    DocBrowser.URL_OPENER[] = url -> push!(OPENED, url)
    DocBrowser.EDITOR[] = (file, line) -> push!(EDITED, (file, line))
    # Only web links are handed to the system, which would run or open a local file.
    empty!(OPENED)
    DocBrowser.follow!(b, DocBrowser.URLTarget("file:///tmp/x.sh"))
    DocBrowser.follow!(b, DocBrowser.URLTarget("../x.md"))
    @test isempty(OPENED) && occursin("Not a web link", b.status)
    # `e` on a selected row opens that name's source.
    DocBrowser.show_module!(b, Fixture)
    frame(b)
    b.focus = :names
    b.names.cursor = findfirst(r -> r.entry !== nothing && r.entry.name === :documented, b.name_rows)
    press!(b, 'e')
    @test endswith(EDITED[end][1], "runtests.jl")
end

@testset "package pages" begin
    cat = Catalog()
    for role in DocBrowser.SECTION_ORDER
        p = DocBrowser.section_page(cat, role, 80)
        @test occursin(getfield(DocBrowser.SECTION_TITLES, role), String(p.lines[2]))
    end
    # How each kind of package describes its place in the environment.
    id = Base.PkgId(Base.UUID(UInt128(2)), "Fixture")
    roles = Dict(:project => "the active project", :direct => "direct dependency",
                 :indirect => "indirect dependency", :extension => "package extension")
    # a module that is not bound in `Main`, where `Pkg.test` runs these tests
    m = Module(:RoleFixture)
    for (role, words) in roles
        cat.bymod[m] = DocBrowser.PkgEntry(m, id, v"1.2.3", role, ["Base", "Core"], "Base")
        text = join(first.(DocBrowser.role_line(cat, m)))
        @test occursin(words, text)
        role === :indirect && @test occursin("loaded by Base → Core", text)
    end
    # A standard library says so, wherever it is.
    cat.bymod[Fixture] = DocBrowser.PkgEntry(Fixture, Base.PkgId(Markdown), nothing, :indirect, String[], "Base")
    @test occursin("indirect dependency · standard library", join(first.(DocBrowser.role_line(cat, Fixture))))
    @test occursin("submodule of", join(first.(DocBrowser.role_line(cat, Fixture.Inner))))
    delete!(cat.bymod, Fixture)
    # An extension shows neither the README nor the links of the package it extends.
    cat.bymod[UndocumentedExt] = DocBrowser.PkgEntry(UndocumentedExt, id, nothing, :extension, String[], "Base")
    text = join(String.(module_page(cat, UndocumentedExt, 80).lines), '\n')
    @test occursin("No docstring found", text)
    @test !occursin("search the web", text)
    delete!(cat.bymod, UndocumentedExt)
    # Standard libraries shipped with Julia show no version.
    @test cat.bymod[Markdown].version === nothing
    @test !DocBrowser.is_bundled(Fixture)
    @test occursin("workspace", join(first.(DocBrowser.role_line(cat, Main))))
    # Licences are recognised from the start of the licence file.
    mktempdir() do dir
        @test DocBrowser.licence(dir) === nothing
        write(joinpath(dir, "LICENSE.md"), "MIT License\n\nCopyright (c) 2020")
        @test DocBrowser.licence(dir) == "MIT"
        write(joinpath(dir, "LICENSE.md"), "                 Apache License\n           Version 2.0")
        @test DocBrowser.licence(dir) == "Apache-2.0"
        write(joinpath(dir, "LICENSE.md"), "All rights reserved by nobody in particular.")
        @test DocBrowser.licence(dir) == "see LICENSE.md"
        write(joinpath(dir, "COPYING"), "SPDX-License-Identifier: BSD-3-Clause WITH some-exception")
        write(joinpath(dir, "GPL-3.0+"), "")
        @test DocBrowser.licence(dir) == "BSD-3-Clause, GPL-3.0+"
        rm(joinpath(dir, "COPYING")); rm(joinpath(dir, "GPL-3.0+"))
        # The docs link comes from a README badge, preferring the stable docs.
        @test DocBrowser.docs_url(dir) === nothing
        write(joinpath(dir, "README.md"), """
            [![CI](https://x.org/ci.svg)](https://github.com/o/P.jl/actions)
            [![Dev](https://img.shields.io/badge/docs-dev-blue.svg)](https://o.github.io/P.jl/dev)
            [![][docs-stable-img]][docs-stable-url]

            [docs-stable-img]: https://img.shields.io/badge/docs-stable-blue.svg?style=flat
            [docs-stable-url]: https://o.github.io/P.jl/stable
            """)
        @test DocBrowser.docs_url(dir) == "https://o.github.io/P.jl/stable"
        pb = DocBrowser.PageBuilder(80)
        DocBrowser.add_links!(pb, id, dir, :indirect)
        @test occursin("docs o.github.io/P.jl/stable", String(pb.lines[end]))
        write(joinpath(dir, "README.md"), "<a href=\"https://o.github.io/P.jl/dev\"><img src=\"docs-dev.svg\"></a>")
        @test DocBrowser.docs_url(dir) == "https://o.github.io/P.jl/dev"
        # Without a badge, a plain link to docs, as Makie's backends have, but not Julia's manual.
        write(joinpath(dir, "README.md"), """
            See the [Julia manual](https://docs.julialang.org/en/v1/) first.
            Read the docs for P and its backends [here](http://docs.p.org/stable).
            """)
        @test DocBrowser.docs_url(dir) == "http://docs.p.org/stable"
        write(joinpath(dir, "README.md"), "See the [Julia manual](https://docs.julialang.org/en/v1/).")
        @test DocBrowser.docs_url(dir) === nothing
        # The package's own `[docs] url` comes first, for the installed version.
        write(joinpath(dir, "Project.toml"), "version = \"1.2.3\"\n\n[docs]\nurl = \"https://o.github.io/P.jl/v{version}/\"\n")
        @test DocBrowser.docs_url(dir) == "https://o.github.io/P.jl/v1.2.3/"
        rm(joinpath(dir, "Project.toml"))
    end
    # Where the browser looked for a package's docs, and why it found no more.
    report = sprint(io -> DocBrowser.explain_docs(DocBrowser; io))
    @test startswith(report, "DocBrowser ") && occursin(r"docs/\s+\d+ pages of a manual", report)
    @test occursin(r"\[docs\]\s+none in its project file", report) && occursin("hosted docs", report)
    # A standard library in Julia's repository has Julia's licence, and a JLL that of its library.
    pb = DocBrowser.PageBuilder(200)
    DocBrowser.add_links!(pb, Base.PkgId(Markdown), pkgdir(Markdown), :stdlib)
    @test occursin("licence MIT", String(pb.lines[end]))
    libs = DocBrowser.jll_licence_dir(Base.PkgId(nothing, "OpenBLAS_jll"))
    isdir(libs) && @test DocBrowser.licence(libs) !== nothing
    # Julia's manual is linked at the address deployed for each kind of build.
    for (v, ver) in (v"1.13.4" => "v1.13", v"1.15.0-DEV.1234" => "v1.15-dev",
                     v"1.13.5-DEV.12" => "v1.13-dev", v"1.14.0-beta1.5" => "v1.14-dev")
        @test DocBrowser.julia_docs("stdlib/REPL/", v) == "https://docs.julialang.org/en/$ver/stdlib/REPL/"
    end
    # README badges and HTML are dropped.
    md = DocBrowser.strip_badges!(Markdown.parse("""
        [![CI](https://x/ci.svg)](https://x/ci) ![logo](logo.png)

        <p align="center">hello</p>

        Some text.
        """))
    @test length(md.content) == 1
end

@testset "repositories from a registry or a manifest" begin
    uuid = Base.UUID("7876af07-990d-54b4-ab0e-23690620f79a")
    id = Base.PkgId(uuid, "NotRegisteredAnywhere")
    mktempdir() do depot
        reg = joinpath(depot, "registries", "Test")
        mkpath(joinpath(reg, "N", "NotRegisteredAnywhere"))
        write(joinpath(reg, "Registry.toml"), """
            name = "Test"
            [packages]
            $uuid = { name = "NotRegisteredAnywhere", path = "N/NotRegisteredAnywhere" }
            """)
        write(joinpath(reg, "N", "NotRegisteredAnywhere", "Package.toml"),
              "repo = \"https://github.com/someone/NotRegisteredAnywhere.jl.git\"\n")
        pushfirst!(DEPOT_PATH, depot)
        try
            @test DocBrowser.repo_url(id, nothing) == "https://github.com/someone/NotRegisteredAnywhere.jl"
        finally
            popfirst!(DEPOT_PATH)
        end
    end
    mktempdir() do dir
        write(joinpath(dir, "Project.toml"), "[deps]\nNotRegisteredAnywhere = \"$uuid\"\n")
        write(joinpath(dir, "Manifest.toml"), """
            manifest_format = "2.0"
            [[deps.NotRegisteredAnywhere]]
            uuid = "$uuid"
            repo-url = "git@gitlab.com:someone/NotRegisteredAnywhere.jl.git"
            """)
        old = Base.active_project()
        Base.set_active_project(joinpath(dir, "Project.toml"))
        try
            @test DocBrowser.repo_url(id, nothing) == "https://gitlab.com/someone/NotRegisteredAnywhere.jl"
        finally
            Base.set_active_project(old)
        end
    end
end

# An output whose size can change, like a terminal window being resized.
mutable struct ResizableIO <: IO
    buf::IOBuffer
    size::Tuple{Int,Int}
end
Base.displaysize(io::ResizableIO) = io.size
Base.unsafe_write(io::ResizableIO, p::Ptr{UInt8}, n::UInt) = unsafe_write(io.buf, p, n)
Base.write(io::ResizableIO, x::UInt8) = write(io.buf, x)
Base.flush(io::ResizableIO) = nothing

@testset "resizing" begin
    out = ResizableIO(IOBuffer(), (30, 120))
    b = Browser(FakeTerminal(IOBuffer(""), out, IOBuffer()))
    DocBrowser.draw(b)
    @test !DocBrowser.check_size!(b)
    out.size = (20, 70)
    @test DocBrowser.check_size!(b)
    @test (b.height, b.width) == (20, 70) && isempty(b.prev)
    DocBrowser.draw(b)
    @test length(b.prev) == 20
end

@testset "the terminal's colours" begin
    @test DocBrowser.parse_colour("rgb:1e1e/1e1e/1e1e") == 0x1e1e1e
    @test DocBrowser.parse_colour("rgb:f/8/0") == 0xff8800
    @test DocBrowser.parse_colour("#ffffff") === nothing
    @test DocBrowser.is_dark(0x1e1e1e) && !DocBrowser.is_dark(0xfafafa)
    @test DocBrowser.mix_colour(0x000000, 0xffffff, 0.5) == 0x808080
    # The background sets dark or light until the terminal says so outright, and redraws.
    b = Browser(fake_terminal(""))
    b.theme = nothing
    frame(b); b.prev = ["x"]
    @test handle!(b, DocBrowser.SchemeEvent(nothing, "rgb:fafa/fafa/fafa"))
    @test b.theme === :light && b.bg == 0xfafafa && isempty(b.prev)
    handle!(b, DocBrowser.SchemeEvent(nothing, "rgb:0000/0000/0000"))
    @test b.theme === :light
    handle!(b, DocBrowser.SchemeEvent(true, ""))
    @test b.theme === :dark
    @test !handle!(b, DocBrowser.SchemeEvent(nothing, "nonsense"))
    # The shades are mixed from the background the terminal reported.
    faces = Dict(DocBrowser.theme_faces(:dark, UInt32(0x101010)))
    @test faces[:REPL_DocBrowser_bar] == StyledStrings.Face(background=StyledStrings.SimpleColor(0x1c1c1c))
end

@testset "search engine" begin
    @test DocBrowser.web_search("Foo").url == "https://duckduckgo.com/?q=Foo.jl"
    withenv("JULIA_DOCBROWSER_SEARCH_URL" => "https://example.org/find?q=%s&lang=en") do
        @test DocBrowser.web_search("Foo").url == "https://example.org/find?q=Foo.jl&lang=en"
        @test DocBrowser.web_search("Ünï code!").url ==
            "https://example.org/find?q=%C3%9Cn%C3%AF%20code%21.jl&lang=en"
    end
    # Without a place for the query the setting is ignored.
    withenv("JULIA_DOCBROWSER_SEARCH_URL" => "https://example.org") do
        @test DocBrowser.web_search("Foo").url == "https://duckduckgo.com/?q=Foo.jl"
    end
end

@testset "headings at every level" begin
    md = Markdown.parse("# One\n\ntext\n\n## Two\n\ntext\n\n### Three\n\ntext\n\n#### Four\n\ntext\n")
    pb = DocBrowser.PageBuilder(60)
    DocBrowser.add_markdown!(pb, md, Main, Catalog(); contents=true)
    p = DocBrowser.Page(pb)
    @test [strip(String(p.lines[i])) for i in p.headings] == ["One", "Two", "Three", "Four"]
end

@testset "REPL help mode" begin
    @test DocBrowser.is_docs_place("docs: Base.sum")
    @test DocBrowser.is_docs_place("  https://docs.julialang.org/en/v1/base/collections/")
    @test DocBrowser.is_docs_place("https://pkgdocs.julialang.org/v1/environments/")
    @test !DocBrowser.is_docs_place("sum") && !DocBrowser.is_docs_place("https://example.org")

    repl = REPL.LineEditREPL(FakeTerminal(IOBuffer(), IOBuffer(), IOBuffer()), true)
    repl.interface = REPL.setup_interface(repl)
    modes = repl.interface.modes
    help = only(filter(m -> endswith(DocBrowser.prompt_text(m), "help?> "), modes))
    julia_prompt = only(filter(m -> endswith(DocBrowser.prompt_text(m), "julia> "), modes))
    enter, done, question = help.keymap_dict['\r'], help.on_done, julia_prompt.keymap_dict['?']
    DocBrowser.install(repl)
    @test help.keymap_dict['\r'] !== enter && help.on_done !== done
    @test julia_prompt.keymap_dict['?'] !== question
    @test haskey(help.keymap_dict['\e'], '\r')
    # a second install leaves the bindings as they are
    enter = help.keymap_dict['\r']
    DocBrowser.install(repl)
    @test help.keymap_dict['\r'] === enter
end

@testset "downloaded package manuals" begin
    depot = mktempdir()
    pushfirst!(DEPOT_PATH, depot)
    DocBrowser.RECORDS[] = nothing
    DocBrowser.ANY_FETCHED[] = nothing
    try
        pkg(name) = (dir = joinpath(depot, "packages", name, "abcde"); mkpath(dir);
                     write(joinpath(dir, "Project.toml"), "name = \"$name\"\nversion = \"1.0.0\"\n"); dir)
        foo, bar, baz = pkg("Foo"), pkg("Bar"), pkg("Baz")
        @test DocBrowser.wants_manual(foo) && DocBrowser.fetched_docs_dir(foo) === nothing
        # A manual downloaded for a package is kept once by its tree hash, and found again in another session.
        sha = "1"^40
        src = joinpath(DocBrowser.tree_dir(depot, sha), "docs", "src")
        mkpath(src)
        write(joinpath(src, "index.md"), "# Foo\n\nIts manual.\n")
        DocBrowser.save_records!(Dict("Foo/abcde" => Dict{String,Any}("tree" => sha, "source" => "o/r v1.0.0 docs")))
        DocBrowser.RECORDS[] = nothing
        @test DocBrowser.fetched_docs_dir(foo) == DocBrowser.tree_dir(depot, sha) && !DocBrowser.wants_manual(foo)
        @test length(DocBrowser.own_or_fetched_docs(foo).pages) == 1
        # One that cannot have a manual is not looked for again; one that failed is, after a day.
        DocBrowser.save_records!(Dict("Bar/abcde" => Dict{String,Any}("none" => "at the top of its repository"),
                                      "Baz/abcde" => Dict{String,Any}("failed" => round(Int, time()), "reason" => "x")))
        @test !DocBrowser.wants_manual(bar) && !DocBrowser.wants_manual(baz)
        DocBrowser.save_records!(Dict("Baz/abcde" => Dict{String,Any}("failed" => round(Int, time()) - 2 * 86400, "reason" => "x")))
        @test DocBrowser.wants_manual(baz)
    finally
        popfirst!(DEPOT_PATH)
        DocBrowser.RECORDS[] = nothing
        DocBrowser.ANY_FETCHED[] = nothing
    end
    # While manuals download, the footer says so; the tests turn downloading by itself off.
    b = test_browser()
    b.fetch_note = "Downloading the manuals of Foo…"
    @test occursin("Downloading the manuals of Foo…", strip_ansi(frame(b)[end]))
    @test !DocBrowser.autodownload_enabled()
end

@testset "plain text for agents" begin
    # A page, with its links numbered and listed in a form that lookup takes again.
    page = DocBrowser.lookup("Fixture.documented")
    @test startswith(page, "# Main.Fixture.documented") && occursin("Calls documented_public[1]", page)
    @test occursin("[1] Main.Fixture.documented_public", page)
    @test occursin("Public but not exported", DocBrowser.lookup("Main.Fixture.documented_public"))
    @test occursin("Nothing is called", DocBrowser.lookup("Fixture.nosuchname"))
    # An example keeps its short lines, which have only the place that copies the code.
    @test occursin("    julia> 1 + 1\n    2\n", DocBrowser.lookup("Shape"))
    # The outline of a manual page, and one of its sections.
    outline = DocBrowser.lookup("manual/arrays"; outline=true)
    k = parse(Int, match(r"§(\d+) Broadcasting\n", outline)[1])
    section = DocBrowser.lookup("manual/arrays"; section=k)
    @test occursin("element-by-element", section) && !occursin("Array literals\n", section)
    # Each answer says where its file is, to be read directly: the page's, and that of a linked page.
    arrays = joinpath(DocBrowser.manual_dir(), "manual", "arrays.md")
    @test occursin("\nPath: $arrays\n", section)
    @test occursin(r"\[\d+\] manual/[\w-]+#[\w-]+  \S+\.md\n", section)
    sortpage = DocBrowser.lookup("Base.sort!")
    @test occursin(r"\nPath: \S+sort\.jl:\d+\n", sortpage) && !occursin("~/", sortpage)
    # The mark of a link in code goes after the code, so that the code stays as written.
    @test occursin(r"lt\(by\(x\), by\(y\)\)\[\d+\]", sortpage)
    # In brief, each of the docstrings, though they come from one module.
    brief = DocBrowser.lookup("Base.sort!"; brief=true)
    @test occursin("sort!(A; dims", brief) && occursin("sort!(v; alg", brief)
    # Code with a space after the name is a command or an expression, not a name to link.
    @test DocBrowser.resolve_ref("mv a b", Main, Catalog()) === nothing
    @test DocBrowser.resolve_ref("float = false", Main, Catalog()) === nothing
    @test DocBrowser.resolve_ref("@time f()", Main, Catalog()) !== nothing
    @test DocBrowser.lookup("manual/arrays#Broadcasting") == section
    # A package of the project that is not loaded is not hidden by an internal name of Base,
    # as the package Downloads would be by `Base.Downloads`.
    cat = Catalog()
    id = Base.PkgId(Base.UUID("5d9c9a4e-3b0e-4f53-9c1e-6c1f2a7b8d21"), "IRShow")
    push!(cat.unloaded, id)
    @test DocBrowser.agent_target(cat, "IRShow", Main) == DocBrowser.LoadTarget(id, "")
    @test DocBrowser.agent_target(cat, "IRShow.f", Main) == DocBrowser.LoadTarget(id, "f")
    # Searching, and the names of a module.
    @test occursin("Base.sort!  function, exported", DocBrowser.find_docs("sort!"))
    names = DocBrowser.list_names(Fixture)
    @test occursin("documented  exported", names) && !occursin("helper", names)
    @test occursin("helper  internal", DocBrowser.list_names("Fixture"; internal=true))
    # The command line.
    out = mktemp() do path, io
        code = redirect_stdout(() -> DocBrowser.main(["--section", "1", "show", "Base.sort!"]), io)
        close(io)
        (code, read(path, String))
    end
    @test out[1] == 0 && startswith(out[2], "# Base.sort!  (Julia $VERSION)")
    @test redirect_stderr(() -> DocBrowser.main(String[]), devnull) == 1
    @test redirect_stdout(() -> DocBrowser.main(["--help"]), devnull) == 0
    # An option the command does not have, or a command that does not exist, is an error.
    for args in (["show", "x", "--sectoin", "2"], ["names", "x", "--text"], ["show", "x", "--section", "x"], ["frob", "x"])
        @test redirect_stderr(() -> DocBrowser.main(args), devnull) == 2
    end
    # Finding nothing is said by the exit code too.
    @test redirect_stdout(() -> DocBrowser.main(["show", "Fixture.nosuchname"]), devnull) == 1
    # Several commands in one call, split by `+` or read from standard input, each under a line
    # that says which it is. Finding nothing for any of them is said by the exit code.
    out = mktemp() do path, io
        code = redirect_stdout(() -> DocBrowser.main(["find", "sort!", "+", "show", "Base.sort!", "--brief"]), io)
        close(io)
        (code, read(path, String))
    end
    @test out[1] == 0 && startswith(out[2], "## jldocs find sort!\n") &&
        occursin("\n\n## jldocs show Base.sort! --brief\n# Base.sort!", out[2])
    out = mktemp() do path, io
        write(io, "names Fixture\n\nshow Fixture.nosuchname\n")
        seekstart(io)
        redirect_stdin(io) do
            mktemp() do opath, oio
                code = redirect_stdout(() -> DocBrowser.main(["-"]), oio)
                close(oio)
                (code, read(opath, String))
            end
        end
    end
    @test out[1] == 1 && occursin("## jldocs names Fixture\n", out[2]) && occursin("## jldocs show Fixture.nosuchname\n", out[2])
    for args in (["find", "x", "+"], ["find", "x", "+", "frob", "y"], ["find", "x", "--project", "a", "+", "show", "y", "--project", "b"])
        @test redirect_stderr(() -> DocBrowser.main(args), devnull) == 2
    end
    DocBrowser.CLI[] = false
end

@testset "plain text: the manual, and docstrings from several modules" begin
    @test occursin("\n  manual/arrays  ", DocBrowser.lookup("manual"))
    @eval module DocA
        "    f(x)\n\nA's f.\n\n# Notes\n\nMore about A."
        f(x) = 1
    end
    @eval module DocB
        import ..DocA
        "    f(::String)\n\nB's method of f.\n\n# Notes\n\nMore about B."
        DocA.f(::String) = 2
    end
    # Each docstring says which module it is from, and so does each heading in the outline.
    page = DocBrowser.lookup("DocA.f")
    @test occursin(r"From Main.DocA\[\d+\]:", page) && occursin(r"From Main.DocB\[\d+\]:", page)
    @test occursin("§1 Notes  (from Main.DocA)\n§2 Notes  (from Main.DocB)", DocBrowser.lookup("DocA.f"; outline=true))
    # In brief, the signature and first paragraph of each.
    brief = DocBrowser.lookup("DocA.f"; brief=true)
    @test occursin("A's f.", brief) && occursin("B's method of f.", brief) && !occursin("More about", brief)
end

foreach((r, v) -> r[] = v, SETTINGS, SAVED)
