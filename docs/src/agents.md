# For AI agents

Coding agents often look up Julia docs on the web or from memory, and get the wrong version.
The `jldocs` command gives them the same pages as the browser, as plain text, for the exact
versions your project uses, offline.

## 1. Install it

```
pkg> app add DocBrowser
```

This uses Pkg's (experimental) apps, and puts `jldocs` in `~/.julia/bin`, which needs to be
on your `PATH`.

## 2. Tell your agents

Agents use a tool when their instructions mention it. Add this to your global instructions
(`~/.claude/CLAUDE.md` for Claude Code, `~/.codex/AGENTS.md` for Codex), or to one project's
`AGENTS.md`:

```
For Julia documentation, run `jldocs find <words>` and `jldocs show <name>`
(see `jldocs --help`) before searching the web or relying on memory.
```

For more detail, such as how to read long pages without filling the context, there is a
[skill](https://github.com/JuliaLang/DocBrowser.jl/tree/main/skills/julia-docs). For Claude
Code, copy its directory to `~/.claude/skills/julia-docs`.

## What it can do

| Command | Gives |
|:--------|:------|
| `jldocs find sort` | names and manual sections that match |
| `jldocs show Base.sort!` | a page, with its links numbered |
| `jldocs show Base.sort! --brief` | each docstring's signature and first paragraph |
| `jldocs show manual/arrays --outline` | the headings of a long page |
| `jldocs show manual/arrays --section 21` | one of those headings |
| `jldocs show GLMakie/` | the pages of a package's manual |
| `jldocs names Plots --load` | the names in a module |
| `jldocs find sort + show Base.sort!` | several answers for one start of Julia |

- It works in the project of the current directory, or `--project PATH`.
- It doesn't load your packages (which runs their code) unless you add `--load`.
- Every page gives its local file as `Path:`, so an agent can also read or `grep` it.
- Several commands, split by `+` or one a line from standard input with `jldocs -`, start Julia
  and load packages once. Each answer starts with a `## jldocs <command>` line.
- It exits with 0 for an answer, 1 when nothing was found, and 2 for a mistake in the command.

Without the app, `julia --project -m DocBrowser ...` does the same, and in Julia
[`DocBrowser.find_docs`](@ref), [`DocBrowser.lookup`](@ref) and
[`DocBrowser.list_names`](@ref) return the same text.

## An example

Asked how to set the size of a GLMakie window, an agent might run:

```
$ jldocs find px_per_unit
GLMakie/explanations/figure#The-px_per_unit-factor  manual of GLMakie: The px_per_unit factor  /…/docs/src/explanations/figure.md

$ jldocs show GLMakie/explanations/figure --outline
# GLMakie/explanations/figure  (GLMakie 0.13.17)
Path: /…/docs/src/explanations/figure.md
§1 Figures
…
§7 Figure size and resolution
§8 The px_per_unit factor

$ jldocs show GLMakie/explanations/figure#The-px_per_unit-factor
```
