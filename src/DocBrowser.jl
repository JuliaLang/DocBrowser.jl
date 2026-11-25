"""
    DocBrowser

A full-window, mouse-aware browser for Julia's manual and the documentation of every loaded
module. Press Enter at an empty `help?>` prompt to open it, or call [`DocBrowser.browse`](@ref).

The same pages are available as plain text, for programs and AI agents:
[`DocBrowser.find_docs`](@ref) searches, [`DocBrowser.lookup`](@ref) shows a page, and
[`DocBrowser.list_names`](@ref) lists the names of a module. From a shell, the `jldocs` app
(`pkg> app add`) and `julia -m DocBrowser` do the same; `jldocs --help` says how.
"""
module DocBrowser

import REPL
using Base: PkgId, UUID, AnnotatedString, annotations
using Base.Docs: Binding, MultiDoc, DocStr
using Markdown
using StyledStrings: StyledStrings, Face, addface!, face!, AnnotatedIOBuffer
import InteractiveUtils
using Base64: base64encode

export browse
public fetch_package_docs, explain_docs, lookup, find_docs, list_names

# The defaults use only the 16 named colours, so they follow the terminal's palette and
# work on any terminal, light or dark. Each pairing keeps a WCAG contrast of at least 4.5:1
# (3:1 for bold text) on the default palettes of common dark terminals, and on light ones
# where the ANSI colours allow. Secondary text uses `shadow`, which no dark theme draws at
# 4.5:1, so it only holds detail. See `rich_faces` for terminals with more colours.
const FACES = (
    :REPL_DocBrowser_title        => Face(weight=:bold),
    :REPL_DocBrowser_pane_title   => Face(weight=:bold),
    :REPL_DocBrowser_border       => Face(inherit=:shadow),
    :REPL_DocBrowser_section      => Face(weight=:bold),
    :REPL_DocBrowser_bar          => Face(),
    :REPL_DocBrowser_selected     => Face(background=:blue, foreground=:bright_white, weight=:bold),
    :REPL_DocBrowser_unfocused    => Face(inherit=:region, foreground=:bright_white),
    :REPL_DocBrowser_hover        => Face(underline=true),
    :REPL_DocBrowser_selection    => Face(inverse=true),
    :REPL_DocBrowser_cursor       => Face(inherit=:region),
    :REPL_DocBrowser_code_block   => Face(),
    :REPL_DocBrowser_dim          => Face(inherit=:shadow),
    :REPL_DocBrowser_key          => Face(weight=:bold, foreground=:bright_blue),
    :REPL_DocBrowser_tip          => Face(foreground=:green),
    :REPL_DocBrowser_tip_title    => Face(foreground=:green, weight=:bold),
    :REPL_DocBrowser_match        => Face(weight=:bold, underline=true),
    :REPL_DocBrowser_searchbox    => Face(foreground=:bright_white, background=:blue, weight=:bold),
    :REPL_DocBrowser_link         => Face(foreground=:bright_blue, underline=true),
    :REPL_DocBrowser_link_active  => Face(foreground=:bright_white, background=:blue),
    :REPL_DocBrowser_exported     => Face(foreground=:green),
    :REPL_DocBrowser_public       => Face(foreground=:bright_blue),
    :REPL_DocBrowser_internal     => Face(inherit=:shadow),
    :REPL_DocBrowser_kind_module   => Face(foreground=:magenta),
    :REPL_DocBrowser_kind_type     => Face(foreground=:cyan),
    :REPL_DocBrowser_kind_function => Face(foreground=:bright_blue),
    :REPL_DocBrowser_kind_macro    => Face(foreground=:yellow),
    :REPL_DocBrowser_kind_constant => Face(foreground=:green),
    :REPL_DocBrowser_kind_global   => Face(foreground=:bright_red),
    :REPL_DocBrowser_logo_red      => Face(foreground=:red),
    :REPL_DocBrowser_logo_green    => Face(foreground=:green),
    :REPL_DocBrowser_logo_purple   => Face(foreground=:magenta),
)

# With 256 or more colours, and once it is known whether the terminal is light or dark, the
# Julia logo's colours replace the named ones, and the header and footer are shaded. Without
# both, the named colours are kept, since exact colours chosen for one kind of background are
# unreadable on the other. `bg` is the background colour the terminal reported, if it did.
rich_faces(theme=terminal_theme(), bg=nothing) =
    rich_colours() && theme !== nothing ? theme_faces(theme, bg) : ()

# StyledStrings can blend the terminal's own colours from Julia 1.14.
const BLEND = isdefined(StyledStrings, :blend) ? getglobal(StyledStrings, :blend) : nothing

function theme_faces(theme::Symbol, bg)
    rgb(c) = StyledStrings.SimpleColor(c)
    dark = theme === :dark
    shade = if BLEND !== nothing && terminal_theme() !== nothing
        α -> BLEND(:background, :foreground, α)
    else
        # StyledStrings does not know the terminal's colours before Julia 1.14, so the shades
        # are mixed here, from the background towards white or black.
        from, to = something(bg, dark ? 0x1e1e1e : 0xffffff), dark ? 0xffffff : 0x000000
        α -> rgb(mix_colour(from, to, α))
    end
    blue, green, purple, red = dark ? (0x6b8cf0, 0x58b947, 0xb07cd0, 0xe0605a) :
                                      (0x3355c4, 0x2f8a22, 0x8a4ca8, 0xbf3a31)
    accent, onaccent = dark ? (0x2b3f86, 0xffffff) : (0x4063d8, 0xffffff)
    return (
        :REPL_DocBrowser_border       => Face(foreground=shade(0.15)),
        :REPL_DocBrowser_bar          => Face(background=shade(0.05)),
        :REPL_DocBrowser_selected     => Face(background=rgb(accent), foreground=rgb(onaccent), weight=:bold),
        :REPL_DocBrowser_unfocused    => Face(background=shade(0.14), foreground=:foreground),
        :REPL_DocBrowser_cursor       => Face(background=shade(0.08)),
        :REPL_DocBrowser_code_block   => Face(background=shade(0.04)),
        :REPL_DocBrowser_key          => Face(weight=:bold, foreground=rgb(blue)),
        :REPL_DocBrowser_tip          => Face(foreground=rgb(green)),
        :REPL_DocBrowser_tip_title    => Face(foreground=rgb(green), weight=:bold),
        :REPL_DocBrowser_searchbox    => Face(foreground=rgb(0xffffff), background=rgb(0x4063d8), weight=:bold),
        :REPL_DocBrowser_link         => Face(foreground=rgb(blue), underline=shade(0.3)),
        :REPL_DocBrowser_link_active  => Face(foreground=rgb(0xffffff), background=rgb(0x4063d8)),
        :REPL_DocBrowser_exported     => Face(foreground=rgb(green)),
        :REPL_DocBrowser_public       => Face(foreground=rgb(blue)),
        :REPL_DocBrowser_kind_module   => Face(foreground=rgb(purple)),
        :REPL_DocBrowser_kind_type     => Face(foreground=rgb(dark ? 0x5fb8c9 : 0x1c7f8f)),
        :REPL_DocBrowser_kind_function => Face(foreground=rgb(blue)),
        :REPL_DocBrowser_kind_macro    => Face(foreground=rgb(dark ? 0xd7a94b : 0x9a6a00)),
        :REPL_DocBrowser_kind_constant => Face(foreground=rgb(green)),
        :REPL_DocBrowser_kind_global   => Face(foreground=rgb(red)),
        :REPL_DocBrowser_logo_red      => Face(foreground=rgb(LOGO_COLOURS.red)),
        :REPL_DocBrowser_logo_green    => Face(foreground=rgb(LOGO_COLOURS.green)),
        :REPL_DocBrowser_logo_purple   => Face(foreground=rgb(LOGO_COLOURS.purple)),
    )
end

const LOGO_COLOURS = (red=0xcb3c33, green=0x389826, purple=0x9558b2)

rich_colours() = dynamic(Base.get_have_truecolor)()::Bool ||
    dynamic(get)(dynamic(Base.current_terminfo)(), :colors, 0)::Int >= 256

mix_colour(a::UInt32, b::UInt32, α) =
    reduce(|, (round(UInt32, (1 - α) * (a >> s & 0xff) + α * (b >> s & 0xff)) << s for s in (16, 8, 0)))

# A colour as a terminal reports it, `rgb:RRRR/GGGG/BBBB` with one to four hex digits for each.
function parse_colour(s::AbstractString)
    m = match(r"^rgb:([0-9a-fA-F]{1,4})/([0-9a-fA-F]{1,4})/([0-9a-fA-F]{1,4})$", s)
    m === nothing && return nothing
    c(h) = round(UInt32, parse(Int, h; base=16) / (16^length(h) - 1) * 255)
    return c(m[1]) << 16 | c(m[2]) << 8 | c(m[3])
end

is_dark(c::UInt32) = 0.2126 * (c >> 16 & 0xff) + 0.7152 * (c >> 8 & 0xff) + 0.0722 * (c & 0xff) < 128

# `:light` or `:dark` once the REPL has asked the terminal for its colours and
# StyledStrings has applied the matching theme, which is all that changes `region`.
function terminal_theme()
    hasproperty(StyledStrings.FACES, :themes) || return nothing
    region = get(StyledStrings.FACES.current[], :region, nothing)
    region === nothing && return nothing
    for theme in (:light, :dark)
        region == get(getfield(StyledStrings.FACES.themes, theme), :region, nothing) && return theme
    end
    return nothing
end

# The value of `ex`, or of `default` if it fails. An interrupt is passed on, since it is the
# user stopping the work, not the work failing.
macro attempt(ex, default=nothing)
    quote
        try
            $(esc(ex))
        catch err
            err isa InterruptException && rethrow()
            $(esc(default))
        end
    end
end

# Whether `f`, which waits for something, returned within `timeout` seconds. If it did not,
# its task is left to end by itself when what it waits for happens.
function within(f, timeout::Real)
    done = Channel{Bool}(2)
    timer = Timer(_ -> put!(done, false), timeout)
    errormonitor(Threads.@spawn (f(); put!(done, true)))
    ok = take!(done)
    close(timer)
    return ok
end

# Calls whose arguments the browser cannot know the types of, or that packages extend, are left
# to run time through `dynamic`. Otherwise a package that adds a method, such as a `String` for
# its own kind of string, invalidates the compiled code of the browser that calls them, and
# opening the browser compiles most of it again.
dynamic(f) = Base.inferencebarrier(f)
as_string(x) = x isa String ? x : dynamic(String)(x)::String
# Page keys are of many types, so they are compared at run time too.
same_key(a, b) = dynamic(isequal)(a, b)::Bool

include("catalog.jl")
include("pages.jl")
include("manual.jl")
include("pkgdocs.jl")
include("download.jl")
include("fetchdocs.jl")
include("start.jl")
include("input.jl")
include("graphics.jl")
include("ui.jl")
include("repl.jl")
include("agent.jl")
# Without this workload the first open takes about 2 s in every session, nearly all of it
# type inference, which the JIT object cache does not keep. It costs about 17 MiB.
include("precompile.jl")

function __init__()
    foreach(addface!, FACES)
    # A REPL that opens the browser by itself needs no hook.
    isdefined(REPL, :open_docbrowser) || install_when_ready()
end

end
