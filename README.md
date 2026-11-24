# DocBrowser.jl

[![Stable](https://img.shields.io/badge/docs-stable-blue.svg)](https://JuliaLang.github.io/DocBrowser.jl/stable/)
[![Dev](https://img.shields.io/badge/docs-dev-blue.svg)](https://JuliaLang.github.io/DocBrowser.jl/dev/)
[![CI](https://github.com/JuliaLang/DocBrowser.jl/actions/workflows/CI.yml/badge.svg)](https://github.com/JuliaLang/DocBrowser.jl/actions/workflows/CI.yml)

A full-window browser in the REPL for Julia's manual, the manuals of your packages, and the
docstrings of every loaded module.

## Getting started

```
pkg> add DocBrowser

julia> using DocBrowser

help?>            # press Enter at the empty prompt to open the browser

help?> sum        # or type a name and press Alt-Enter to open it there
```

Press `?` in the browser to see every key, and `q` to close it.

To have help mode open the browser in every session, load it in `~/.julia/config/startup.jl`:

```julia
isinteractive() && @eval using DocBrowser
```

Loading it takes about 30 ms at the REPL, almost all of it the precompiled code that makes the
browser open at once. `startup.jl` runs for scripts too, where loading it would also load the
REPL, so the line above skips those. It reads the docs only when the browser opens. Julia 1.12
and later are supported.

## Using it

The browser opens again where it was last closed. `DocBrowser.browse()` and
`DocBrowser.browse(x)` open it from code.

The browser has three panes:

- **Contents:** *Julia*, with its manual (*Manual*, *Base*, *Standard library*, *Developer docs*),
  then *Packages*: the active *Project*, its *Dependencies*, *Indirect* dependencies and
  *Extensions*, and last `Main`, where your own definitions are. Each library is one row: `Core` and `Base` are in *Base*, and the
  standard libraries in *Standard library*. Dependencies that are not loaded yet are listed
  too: select one and press Enter to load it.
- **Names:** the sections of a manual page, or the names in a module, grouped by kind. Each is
  marked `●` if exported, `○` if public, or `·` if internal. Press `i` to show internal and
  deprecated names. A library's manual, if its source has one, is listed first.
- **Documentation:** the docstrings of a name, or a module's docstring or README, with its
  version, licence, repository and online docs. Functions list their methods, and types their
  fields, subtypes and constructors.

Names mentioned in a docstring are links, and so are mentions of packages such as `Example.jl`.
Extended help is folded away until you press `x`, and each example has a link that pastes its
code at the `julia>` prompt.

### Keys and mouse

- Arrow keys or `h` `j` `k` `l` move, Enter opens, Tab steps through a page's links, Backspace goes back.
- `/` searches names first, then the manual and the text of docstrings, and also the names that
  manuals of packages not loaded yet list, which load when picked. Ctrl-T narrows it to names,
  then to text.
- `y` closes the browser and puts the name being viewed at the `julia>` prompt.
- `e` opens the source in your editor (`JULIA_EDITOR`), `w` changes the layout, `?` lists every key.
- In terminals that support it, click anything, scroll, and use the mouse's back and forward buttons.
  Right-click, Alt-click or Ctrl-click opens the source of a method, name, package or link.
- Drag across the documentation to copy text, double-click to copy a word, triple-click for a line.
  To select with your terminal instead, hold the key it uses for this (Shift in most terminals,
  Option in iTerm2, Fn in Terminal.app).

### Links to share

Press `c`, or click `⧉ link` above a page, to copy a link to it, such as
`help?> docs: manual/performance-tips#man-code-warntype`. Pasted at the `julia>` prompt, it
opens the browser at that place. In help mode you can type `docs:` and a page (`manual/variables`,
`stdlib/Pkg/environments`), with `#` and a heading if you like, or a name such as `Base.sum`. The
address of a page of docs.julialang.org or pkgdocs.julialang.org works too.

## The manual

Julia's releases do not include the Markdown source of the manual. The first time the browser
opens, it downloads it (about 1.7 MB) from the Julia repository, at the commit your Julia was
built from, and keeps it in the depot's scratch space. Contents shows *Manual loading…* until
that finishes, or *Manual failed*, whose page has a link to try again. If that commit is not on GitHub,
as for some local builds, the nearest version is downloaded instead, and its pages say so. To
download it ahead of time, for example before going offline, run `DocBrowser.download_manual()`.

The standard libraries, including Pkg, ship their manuals with their source, so those are
always there.

### Package manuals

Most packages keep their manual's pages in `docs/src`, so the browser shows them, in the order
that `docs/make.jl` gives, and expands their `@autodocs` blocks into lists of names. They come
from the installed version of the package, so a package whose release predates its `docs/`
directory shows only its README and docstrings until its next release.

Pages that the documentation build writes, such as Literate tutorials, are not in the source.
When some are missing, the package's pages say so and link to its online docs.

A package in a subdirectory of a repository, such as GLMakie in Makie.jl, is installed without
a manual that is kept elsewhere in the repository. The browser downloads such manuals in the
background when it opens, from the release of each installed version, saying so in its footer,
and a package's page has a button to try again. Packages of one repository are looked for
together and share one copy, so that GitHub's limit of 60 requests an hour without a
`GITHUB_TOKEN` is seldom reached; what is left is tried again later. A package can say where its manual is, and where its hosted
docs are, in a `[docs]` section of its project file:

```toml
[docs]
url = "https://example.github.io/Example.jl/v{version}/"
source = "../docs/src"
```

When a package's manual does not show, `DocBrowser.explain_docs("Example")` says where the
browser looked and why it found no more.

## Settings

- `JULIA_DOCBROWSER_SEARCH_URL`: the search engine for packages whose repository the browser
  cannot find, with `%s` where the query goes, e.g. `https://www.google.com/search?q=%s`.
  The default is DuckDuckGo.
- `JULIA_DOCBROWSER_AUTODOWNLOAD`: `no` stops the browser from downloading packages' manuals
  by itself. The button on a package's page still does.
- `GITHUB_TOKEN`: raises GitHub's limit on the requests that finding those manuals makes.

## For AI agents

The pages are also available as plain text, so that coding agents can read the documentation
of the exact package versions a project uses, offline, instead of searching the web. Install
the `jldocs` command with Pkg's (experimental) app support, and put `~/.julia/bin` on your
`PATH`:

```
pkg> app add DocBrowser
```

```
jldocs find sort                         # names and manual sections that match
jldocs show Base.sort!                   # a page, with its links numbered
jldocs show Base.sort! --brief           # just each docstring's signature and first paragraph
jldocs show manual/arrays --outline      # the headings of a long page...
jldocs show manual/arrays --section 21   # ...and one of them
jldocs show GLMakie/                     # the pages of a package's manual
jldocs names Plots                       # the names of a module
jldocs find sort + show Base.sort!       # several commands, for one start of Julia
```

It works in the project of the current directory, or the one `--project PATH` names. A package
a name is asked for in, such as Plots for `jldocs show Plots.plot`, is loaded, which runs its code,
unless it would have to be precompiled first. `--load` precompiles it too, and loads all the
project's packages for `find` and for a name found only once they are loaded. Without
the app, `julia --project -m DocBrowser ...` does the same in an environment that has DocBrowser,
and in Julia `DocBrowser.find_docs`, `DocBrowser.lookup` and `DocBrowser.list_names` return the
same text.

Most of the time a command takes is starting Julia and loading packages, so several commands
can share one call, split by `+`, or one a line from standard input with `jldocs -`. Each answer
then starts with a `## jldocs <command>` line, and `--load` in any of them loads the packages for
all of them.

### What an agent does with it

Asked how to set the size of a GLMakie window, in a project that uses GLMakie, an agent might
run:

```
$ jldocs find px_per_unit
GLMakie/explanations/figure#The-px_per_unit-factor  manual of GLMakie: The px_per_unit factor  /…/docs/src/explanations/figure.md
(The names of a package of the project that is not loaded were not searched: GLMakie. …)

$ jldocs show GLMakie/explanations/figure --outline
# GLMakie/explanations/figure  (GLMakie 0.13.17)
Path: /…/docs/src/explanations/figure.md
§1 Figures
…
§7 Figure size and resolution
§8 The px_per_unit factor

$ jldocs show GLMakie/explanations/figure#The-px_per_unit-factor    # or --section 8
```

Every answer is for the versions the project uses, and says what it could not see, such as the
names of packages that are not loaded. Each page gives the local file it comes from as `Path:`,
so the agent can also read or `grep` the Markdown or source directly. A lookup that finds
nothing exits with 1, and a mistake in the command with 2, so an agent can tell them apart from
an answer.

### Telling agents about it

Agents use the tool when their instructions mention it. To have every agent you use know about
it, in every project, add a line to your global instructions: `~/.claude/CLAUDE.md` for Claude
Code, or `~/.codex/AGENTS.md` for Codex, for example:

```
For Julia documentation, run `jldocs find <words>` and `jldocs show <name>`
(see `jldocs --help`) before searching the web or relying on memory.
```

For one project, the same line goes in its `AGENTS.md` or `CLAUDE.md`. For more detail, such as
how to read long pages without filling the context, install the skill in
[`skills/julia-docs`](skills/julia-docs/SKILL.md): for Claude Code, copy that directory to
`~/.claude/skills/julia-docs`.

## How it hooks into the REPL

Julia has no hook for this yet, so on loading, the package changes the running REPL's help mode:
it binds Enter and Alt-Enter, and handles pasted `help?> docs: ...` lines. It also binds `?` at
the `julia>` prompt, to show a hint on the empty `help?>` prompt. Your own key bindings for
those keys are kept underneath and still run for everything else.

## As a standard library

[JuliaLang/julia#64993](https://github.com/JuliaLang/julia/pull/64993) proposes shipping this
package with Julia as a standard library. In a Julia that does, help mode opens the browser
itself, with nothing to install or load at startup, the manual is installed with Julia, and the
browser is loaded the first time it opens. Loading the package there changes nothing.

On other versions of Julia, as a package, it does almost everything that would, but:

- it has to be installed, and loaded from `startup.jl`;
- Julia's manual is downloaded on first use, rather than shipped with Julia, so it is not there
  offline until then;
- a `docs:` link works only for people who have the package;
- it changes the REPL's help mode through REPL internals, which a later Julia could change;
- before Julia 1.14 it keeps to the terminal's 16 named colours, and some tips link to the top of
  a page rather than a heading.

[Issue #2](https://github.com/JuliaLang/DocBrowser.jl/issues/2) compares the two in full.
