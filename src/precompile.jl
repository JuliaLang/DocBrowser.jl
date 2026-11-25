# Drive the browser through its views so the first `help?>` Enter opens it without compiling.
# Only links that stay inside the browser are followed: no editor, web browser or loading.
function precompile_workload()
    function terminal(input::String)
        out = IOContext(IOBuffer(), :displaysize => (32, 120), :color => true)
        return REPL.Terminals.TTYTerminal("xterm", IOBuffer(input), out, IOBuffer())
    end
    b = Browser(terminal(""))
    frame(b)
    keys = Any['j', 'j', 'k', :right, 'j', 'j', :enter, :tab, :tab, :backtab, :down, :pagedown,
               :up, :left, :left, 'a', 'i', 'i', '}', '{', 'w', 'w', 'w', 'w', '?', :escape, '[', ']',
               :backspace, :end, :home]
    for k in keys
        handle!(b, k isa Char ? KeyEvent(k) : KeyEvent(k))
        frame(b)
    end
    follow!(b, NameTarget(Base, :sort!))
    frame(b)
    toggle_flag!(b, :extended)
    frame(b)
    follow!(b, NameTarget(Base, :AbstractVector))
    frame(b)
    follow!(b, ModuleTarget(Base.Iterators))
    follow!(b, AnchorTarget(1))
    frame(b)
    follow!(b, SectionTarget(:basedocs))
    frame(b)
    # Julia's manual is not there when the package is first installed, as it is downloaded when
    # the browser first opens. A page of the package's own manual then stands in for it, so that
    # showing a page of a manual is compiled either way.
    docs = joinpath(something(pkgdir(@__MODULE__), ""), "docs", "src")
    own_page = joinpath(docs, "index.md")
    manual = isempty(b.cat.manual) ? own_page : first(b.cat.manual).path
    if isfile(manual)
        follow!(b, ManualTarget(manual, ""))
        frame(b)
        b.focus = :names
        handle!(b, KeyEvent(:down))
        frame(b)
    end
    for ev in ("/", "s", "o", "r", "t", "\x14", "\x7f", "\e[B", "\e[A", "\t", "\e")
        e = read_event(IOBuffer(ev))
        e === nothing || handle!(b, e)
        frame(b)
    end
    for ev in ("\e[<35;40;8M", "\e[<0;40;8M", "\e[<0;40;8m", "\e[<0;5;5M", "\e[<0;5;5m",
               "\e[<65;90;9M", "\e[<64;90;9M", "\e[<0;100;1M", "\e[200~iter\e[201~", "\e[1;3D",
               "\e]11;rgb:0000/0000/0000\e\\", "\e[?62c",
               "\e[6;15;7t", "\e_Gi=$GRAPHICS_QUERY_ID;OK\e\\", "\e_Gi=$(logo_picture((15, 7)).id);OK\e\\")
        e = read_event(IOBuffer(ev))
        e === nothing || handle!(b, e)
        frame(b)
    end
    # Selecting text in the documentation, without touching the clipboard.
    copy = COPY[]
    COPY[] = (b, text) -> ""
    try
        follow!(b, NameTarget(Base, :sort!))
        for ev in ("\e[<0;70;6M", "\e[<32;90;9M", "\e[<0;90;9m", "\e[<0;70;7M", "\e[<0;70;7m",
                   "\e[<0;70;7M", "\e[<0;70;7m", "\e[<0;70;7M", "\e[<0;70;7m")
            handle!(b, read_event(IOBuffer(ev))::MouseEvent)
            frame(b)
        end
        handle!(b, KeyEvent(:escape))
    finally
        COPY[] = copy
    end
    # The card that previews a name the pointer rests on.
    follow!(b, NameTarget(Base, :sort!))
    frame(b)
    for h in b.hits
        h.action isa Tuple && first(h.action) === :names || continue
        handle!(b, MouseEvent(:move, 0, h.row, first(h.cols), 0))
        b.hover_since = 0.0
        show_card!(b)
        frame(b)
        break
    end
    hide_card!(b)
    for tip in eachindex(TIPS)
        start_page(b.cat, 80, tip)
    end
    unloaded_page(b.cat, PkgId(UUID(UInt128(1)), "Example"), 80)
    # Reading a package's manual, with its list of pages in the forms that builds write.
    dir = pkgdir(@__MODULE__)
    dir === nothing || own_or_fetched_docs(dir)
    doc_page_list("pages = [\"Home\" => \"index.md\", \"Guide\" => joinpath.(\"guide\", [\"a.md\"]), joinpath(\"b\", \"c.md\")]")
    # The event loop, the screen set-up and the entry points.
    browse(terminal("jjlj\ty"); query = "sum")
    browse(terminal("q"), Base.Iterators)
    browse(terminal("q"))
    # The kinds of Markdown that the pages of Julia's manual have, for when it is not there.
    sample = """
        # One
        ## Two
        ### Three
        #### Four
        ##### Five
        ###### Six

        Text with **bold**, *italic*, __bold__, _italic_, `code`, ``x^2``, a [link](https://julialang.org),
        a footnote[^1] and ![an image](image.png).

        [^1]: The footnote, with a [link](https://julialang.org).

        > A quote with a [link](https://julialang.org).

        !!! note
            An admonition with `code`.

        | a                             | b   |
        |:----------------------------- | ---:|
        | [link](https://julialang.org) | `c` |

        1. one
        2. two
             * nested

        ```math
        x^2
        ```

        ---
        """
    add_markdown!(PageBuilder(80), Markdown.parse(sample), Main, b.cat; contents=true)
    # The command line, as an agent runs it.
    page = isempty(b.cat.manual) && isfile(own_page) ? own_page : "manual/arrays"
    for args in (["show", "Base.sort!"], ["show", "Base.sort!", "--brief"], ["show", "manual"],
                 ["show", page, "--outline"], ["show", page, "--section", "1"],
                 ["show", "nosuchname"], ["find", "sort"], ["names", "Base.Iterators"])
        c = parse_command(args)
        c isa AgentCommand && run_command(c)
    end
    precompile(main, (Vector{String},))
    HEADLESS[] = nothing
    FOUND[] = true
    LAST[] = nothing
    LAYOUT[] = :auto
    FIRST_OPEN[] = true
    # what this machine has downloaded is for each session to find out, not the cache to keep
    ANY_FETCHED[] = nothing
    RECORDS[] = nothing
    nothing
end

# Code inferred for other modules' methods is kept too, as PrecompileTools does: without it the
# first open takes twice as long.
if Base.generating_output()
    ccall(:jl_tag_newly_inferred_enable, Cvoid, ())
    try
        precompile_workload()
    finally
        ccall(:jl_tag_newly_inferred_disable, Cvoid, ())
    end
end
