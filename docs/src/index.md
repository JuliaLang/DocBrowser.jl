# [DocBrowser](@id man-docbrowser)

DocBrowser lets you browse Julia's manual, your packages' manuals and every docstring, full
window, right in the REPL. It works offline, and it shows the docs of the versions you have
installed.

![The browser showing the docstring of sort!](https://raw.githubusercontent.com/JuliaLang/DocBrowser.jl/main/docs/src/assets/browser.png)

## Getting started

```
pkg> add DocBrowser

julia> using DocBrowser

help?>                          # press Enter at the empty prompt to open the browser

help?> sum                      # or type a name and press Alt-Enter to open it there

help?> docs: manual/variables   # or go straight to a manual page
```

Press `?` in the browser to see every key, and `q` to close it. It opens again where you left
it.

To have help mode open the browser in every session, add this line to
`~/.julia/config/startup.jl`:

```julia
isinteractive() && @eval using DocBrowser
```

## What you see

The window has three panes, from left to right:

- **Contents:** Julia's manual, then your packages: the active project, its dependencies,
  and `Main` for your own definitions. Packages that aren't loaded yet are listed too; press
  Enter on one to load it.
- **Names:** the sections of a manual page, or the names in a module. `●` marks exported
  names, `○` public ones and `·` internal ones (hidden until you press `i`).
- **Documentation:** the page itself. Names and packages it mentions are links, and long
  pages start with a list of their headings.

## Keys

| Key | Does |
|:----|:-----|
| arrows, or `h` `j` `k` `l` | move |
| Enter / Backspace | open / go back |
| Tab | step through the links of a page |
| `/` | search names, manuals and docstrings (Ctrl-T narrows to names, then to text) |
| `y` | close, and put the current name, or the code under the cursor, at the `julia>` prompt |
| `e` | open the source in your editor (`JULIA_EDITOR`) |
| `c` | copy a link to this place |
| `x` | unfold extended help |
| `i` | show internal and deprecated names |
| `w` | change the layout |
| `?` | list every key |

A search finds names first, then sections of the manuals:

![Searching for broadcast](https://raw.githubusercontent.com/JuliaLang/DocBrowser.jl/main/docs/src/assets/search.png)

## Mouse

In terminals that support it, you can click on anything, scroll, and use the mouse's back and
forward buttons.

- Right-click (or Alt- or Ctrl-click) opens the source of what you click.
- Click `⧉` beside a block of code to copy it.
- Drag to copy text; double-click copies a word, triple-click a line.
- To select with your terminal instead, hold Shift while you drag (Option in iTerm2, Fn in
  Terminal.app).

## Sharing a place

Press `c` (or click `⧉ link` above a page) to copy a link such as
`help?> docs: manual/performance-tips#man-code-warntype`. Paste it at the `julia>` prompt to
open the browser at that place.

After `docs:` you can give:

- a manual page, e.g. `manual/variables` or `stdlib/Pkg/environments`, optionally with
  `#heading`;
- a name, e.g. `Base.sum`;
- the address of a page at docs.julialang.org or pkgdocs.julialang.org.

## Where the docs come from

Everything is read from Markdown on your computer:

- Julia's manual from the copy Julia installs.
- Standard libraries' and packages' manuals from their `docs/src`.
- A package that lives in a subdirectory of a repository (like GLMakie in Makie.jl) comes
  without its manual, so the browser downloads it in the background, for the version you
  have installed.

Pages that a package's docs build generates (Literate tutorials, for example) aren't in its
source, so the browser links to its online docs instead. If a manual is missing and you want
to know why, `DocBrowser.explain_docs("Name")` says where the browser looked.

## Settings

| Environment variable | Effect |
|:---------------------|:-------|
| `JULIA_DOCBROWSER_AUTODOWNLOAD=no` | don't download missing package manuals in the background |
| `JULIA_DOCBROWSER_IMAGES=no` | don't draw pictures, such as the Julia logo and the PNG images in manuals, in terminals with the kitty graphics protocol |
| `JULIA_DOCBROWSER_SEARCH_URL` | the web search for packages with no known repository, with `%s` for the query (default DuckDuckGo) |
| `JULIA_EDITOR` | the editor that `e` opens |

## Reference

```@docs
DocBrowser
DocBrowser.browse
DocBrowser.download_manual
```
