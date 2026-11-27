# The browser: state, layout, drawing and event handling.

struct SideRow
    role::Symbol
    pkg::Union{Nothing,PkgEntry}
    unloaded::Union{Nothing,PkgId} # a dependency that can be loaded from the browser
    page::Union{Nothing,ManualPage}
end
SideRow(role::Symbol, pkg) = SideRow(role, pkg, nothing, nothing)
SideRow(role::Symbol, pkg, unloaded) = SideRow(role, pkg, unloaded, nothing)

is_header(r::SideRow) = r.pkg === nothing && r.unloaded === nothing && r.page === nothing && r.role !== :start

struct NameRow
    # :about, :header, :entry, :heading (of a manual page), :hit (of a search), or :unloaded (a
    # name a search found in the manual of a package that is not loaded)
    kind::Symbol
    entry::Union{Nothing,NameEntry}
    group::Symbol
    count::Int
    hit::Union{Nothing,ManualHit}
    target::Union{Nothing,LoadTarget} # for :unloaded
end
NameRow(kind::Symbol, entry, group::Symbol, count::Int, hit=nothing) = NameRow(kind, entry, group, count, hit, nothing)

mutable struct ListState
    cursor::Int
    scroll::Int
end

struct Hit
    row::Int
    cols::UnitRange{Int}
    action::Any
end

struct Snapshot
    mod::Module
    focus::Symbol
    source::Symbol
    # The selected rows, by what they show rather than where, as unfolding moves them.
    side::Any
    names::Any
    doc_scroll::Int
    override::Any
    query::Union{Nothing,String}
    internal::Bool
    searchmode::Symbol
    link::Int       # the link that was selected, which is often the one that was followed
    title::String   # of the page, to say where going back or forward leads
end

# The state of a browser. A new one is made from its terminal and catalog alone, and every
# other field starts as written here.
Base.@kwdef mutable struct Browser
    term::REPL.Terminals.TextTerminal
    in::IO = term.in_stream
    out::IO = term.out_stream
    cat::Catalog
    height::Int
    width::Int
    focus::Symbol = :side   # the pane keys go to: :side, :names or :doc
    source::Symbol = :side  # the list that picks what the doc pane shows: :side or :names
    side::ListState = ListState(1, 0)
    names::ListState = ListState(1, 0)
    side_rows::Vector{SideRow} = SideRow[]
    name_rows::Vector{NameRow} = NameRow[]
    expanded::Set{Symbol} = Set(DEFAULT_EXPANDED)
    collapsed::Set{Symbol} = Set{Symbol}()
    mod::Module = Main
    internal::Bool = false
    query::Union{Nothing,String} = nothing
    typing::Bool = false
    results::Vector{NameEntry} = NameEntry[]
    override::Any = nothing
    doc_key::Any = nothing
    doc_scroll::Int = 0
    mark::Int = 0       # the line of the heading last jumped to, marked so that the jump shows
    doc_line::Int = 0   # the line of the page the cursor is on, or 0 for the top of the pane
    pointer_block::Int = 0 # the first line of the block of code under the pointer, or 0
    link::Int = 0
    pages::Dict{Tuple{Any,Int,Vector{Symbol}},Page} = Dict{Tuple{Any,Int,Vector{Symbol}},Page}()
    back::Vector{Snapshot} = Snapshot[]
    forward::Vector{Snapshot} = Snapshot[]
    hits::Vector{Hit} = Hit[]
    hover::Any = nothing
    status::String = ""
    help::Bool = false
    quit::Bool = false
    result::Union{Nothing,String} = nothing
    prev::Vector{String} = String[]
    last_click::Tuple{Float64,Any} = (0.0, nothing)
    lock::ReentrantLock = ReentrantLock()
    flags::Dict{Any,Set{Symbol}} = Dict{Any,Set{Symbol}}() # the parts of each page that are unfolded
    searchmode::Symbol = :all    # what a search looks in: :all, or only :names or :text
    layout::Symbol = LAYOUT[]    # :auto, or a number of panes: :one, :two or :three
    color::Bool = has_colour(term)
    # Text selected in the documentation, from where the drag started to where it is now,
    # each as a page line and a column.
    sel::Union{Nothing,NTuple{4,Int}} = nothing
    dragging::Bool = false
    clicks::NTuple{4,Float64} = (0.0, 0.0, 0.0, 0.0) # time, row and column of the last press, and the click count
    under_help::Any = nothing    # the page, scroll and link that the help covers
    manual_hits::Vector{ManualHit} = ManualHit[] # what a search finds in the manual
    manual_titles::Int = 0       # how many of those are titles or headings, which come first
    text_results::Vector{NameEntry} = NameEntry[] # what a search for everything finds only in docstrings' text
    unloaded_hits::Vector{Tuple{String,PkgId}} = Tuple{String,PkgId}[] # what it finds in packages that are not loaded
    indirect::Bool = SEARCH_INDIRECT[] # whether a search includes indirect dependencies
    hidden::Int = 0              # how many names a search found in indirect dependencies, but left out
    # The card that previews what the pointer rests on: where the pointer came to rest and when,
    # and the card's lines and what it previews once it shows.
    hover_at::Tuple{Int,Int} = (0, 0)
    hover_since::Float64 = Inf
    card::Union{Nothing,Tuple{Vector{AnnotatedString{String}},Any}} = nothing
    tips::Vector{Int} = tip_order() # the tips in the order they are shown, shuffled for each browser
    tip::Int = 1                 # which of them the start page shows
    live::Bool = false           # whether it is on the screen, taking input
    card_timer::Union{Nothing,Timer} = nothing # shows the card once the pointer has rested
    # What loading a package printed, shown in a panel above the footer, and what it is doing
    # while it loads, or "". The panel stays after a failure, until the next key.
    console::Union{Nothing,Vector{String}} = nothing
    loading::String = ""
    load_task::Union{Nothing,Task} = nothing
    # Where loads are sent to run on the thread that opened the browser, while the browser
    # runs on another, or `nothing` when they run where they are started.
    loads::Union{Nothing,Channel{Task}} = nothing
    # Shown over the page while a package is being loaded into the session, when the browser
    # stops responding, or "".
    modal::String = ""
    # The world that keys and drawing run in. It moves on only when a package that the browser
    # loaded is done: in the latest world, each method that loading adds makes the browser's
    # calls look up their methods again, which waits for the loading to let go of the method
    # tables, so the browser would stop responding while it loads.
    world::UInt = Base.get_world_counter()
    # The search being typed is a readline field: `qcol` characters of it are before the
    # cursor, and `killed` is what ^W, ^K and the like took last, for ^Y to put back.
    qcol::Int = 0
    killed::String = ""
    # Whether the terminal is light or dark, and its background, as far as is known, and the
    # faces that go with them.
    theme::Union{Nothing,Symbol} = terminal_theme()
    bg::Union{Nothing,UInt32} = nothing
    faces::Vector{Pair{Symbol,Face}} = browser_faces(theme, bg)
    # the rows of each section of the sidebar, for the catalog and manual they were found in
    sections::Tuple{Any,Any,Dict{Symbol,Vector{SideRow}}} = (nothing, nothing, Dict{Symbol,Vector{SideRow}}())
    fetch_note::String = "" # what is being downloaded in the background, for the footer
    # Pictures, where the terminal draws them. `answered` is whether the terminal has said all
    # it will about drawing them, and `cell` the height and width of one of its cells.
    answered::Bool = true
    cell::Tuple{Int,Int} = (2, 1)
    # The pictures the terminal has taken, and those it has yet to answer for, in the order
    # they were sent, at the time `sent`. `gave_up` is whether that is too long ago to
    # expect an answer still.
    pictures::Vector{Picture} = Picture[]
    awaited::Vector{Picture} = Picture[]
    sent::Float64 = 0.0
    gave_up::Bool = false
    # Where pictures go in the frame being drawn, and where they are on the screen.
    placements::Vector{Placement} = Placement[]
    shown::Vector{Placement} = Placement[]
end

function Browser(term::REPL.Terminals.TextTerminal, cat::Catalog=Catalog())
    height, width = displaysize(term)
    b = Browser(; term, cat, height, width)
    any(p -> p.role in (:project, :direct), cat.pkgs) || push!(b.expanded, :indirect)
    refresh_side!(b)
    b.side.cursor = 1 # the start page
    sync_side!(b)
    return b
end

## Rows ##

# The sidebar has two blocks: Julia, with its manual and its own modules, and the loaded
# packages. `Main` is a row of its own after them. Indirect dependencies are a section inside
# the dependencies. A library is one row, which shows its manual and its names: `Core` and
# `Base` are in Base, and the standard libraries in Standard library once they are loaded.
const BLOCKS = (docs = (:manual, :basedocs, :stdlibdocs, :devdocs),
                code = (:project, :direct, :indirect, :extension))
const SECTION_ORDER = (:docs, BLOCKS.docs..., :code, BLOCKS.code...)
const MANUAL_ROLES = BLOCKS.docs
const DEFAULT_EXPANDED = (:docs, :code, :project, :direct)
# The sidebar is narrow, so some of its titles are shorter than those of the sections' pages.
const SIDEBAR_TITLES = merge(SECTION_TITLES, (pkgdocs = "Pkg", devdocs = "Developer docs", indirect = "Indirect"))

is_block(role::Symbol) = role === :docs || role === :code

# Pkg's manual is one row of the sidebar, which stands for all its pages. It shows the first.
pkg_pages(b::Browser) = filter(p -> p.role === :pkgdocs, b.cat.manual)

# Whether the sidebar has anything to list in section `role`.
function has_section(b::Browser, role::Symbol)
    role === :manual && manual_status() !== :none && return true
    return !isempty(section_rows(b, role))
end

# The loaded standard library that a page of the standard library's manual is for.
function stdlib_package(b::Browser, page::ManualPage)
    page.role in (:stdlibdocs, :pkgdocs) || return nothing
    name = page.role === :pkgdocs ? "Pkg" : stdlib_name(page.path)
    i = findfirst(p -> p.id.name == name && p.role !== :extension && is_stdlib(p.id), b.cat.pkgs)
    return i === nothing ? nothing : b.cat.pkgs[i]
end

# The section whose row for package `p` it is picked by.
function package_section(p::PkgEntry)
    p.role === :julia && return :basedocs
    p.role === :indirect && is_stdlib(p.id) &&
        (p.id.name == "Pkg" || stdlib_page(p.id.name) !== nothing) && return :stdlibdocs
    return p.role
end

# The rows of section `role`, when it is unfolded. The sidebar asks for them several times for
# each row it draws, so they are kept until the sidebar is refreshed, or the catalog or its
# manual changes.
function section_rows(b::Browser, role::Symbol)
    cat, manual, rows = b.sections
    if cat !== b.cat || manual !== b.cat.manual
        rows = Dict{Symbol,Vector{SideRow}}()
        b.sections = (b.cat, b.cat.manual, rows)
    end
    return get!(() -> build_section_rows(b, role), rows, role)
end

function build_section_rows(b::Browser, role::Symbol)
    rows = SideRow[]
    if role === :basedocs
        for p in b.cat.pkgs
            p.role === :julia && push!(rows, SideRow(role, p))
        end
    end
    if role in MANUAL_ROLES
        pages = filter(p -> p.role === role, b.cat.manual)
        # Pkg's manual is among the standard libraries, in its place.
        pkg = role === :stdlibdocs ? pkg_pages(b) : ManualPage[]
        if !isempty(pkg)
            k = something(findfirst(p -> lowercase(p.title) > "pkg", pages), length(pages) + 1)
            insert!(pages, k, pkg[1])
        end
        for p in pages
            lib = stdlib_package(b, p)
            if lib === nothing
                push!(rows, SideRow(p.role, nothing, nothing, p))
            elseif !any(r -> r.pkg === lib, rows) # a library with two pages is one row
                push!(rows, SideRow(role, lib))
            end
        end
        return rows
    end
    for p in b.cat.pkgs
        p.role === role && package_section(p) === role && push!(rows, SideRow(role, p))
    end
    if role in (:project, :direct)
        self = project_id()
        for id in b.cat.unloaded
            (id == self) == (role === :project) && push!(rows, SideRow(role, nothing, id))
        end
    end
    return rows
end

function refresh_side!(b::Browser)
    b.sections = (nothing, nothing, Dict{Symbol,Vector{SideRow}}())
    selected = row_key(side_row(b))
    rows = SideRow[SideRow(:start, nothing)]
    for (block, roles) in pairs(BLOCKS)
        any(r -> has_section(b, r), roles) || continue
        push!(rows, SideRow(block, nothing))
        block in b.expanded || continue
        for role in roles
            has_section(b, role) || continue
            # Indirect dependencies are inside the dependencies, when there are any.
            role === :indirect && has_section(b, :direct) && !(:direct in b.expanded) && continue
            push!(rows, SideRow(role, nothing))
            role in b.expanded && append!(rows, section_rows(b, role))
        end
    end
    for p in b.cat.pkgs
        p.role === :main && push!(rows, SideRow(:main, p))
    end
    b.side_rows = rows
    # Keep the same row selected. If it is gone, the names pane must follow the new one.
    i = findfirst(r -> row_key(r) == selected, rows)
    b.side.cursor = something(i, clamp(b.side.cursor, 1, max(1, length(rows))))
    i === nothing && selected !== nothing && refresh_names!(b)
end

function refresh_names!(b::Browser)
    rows = NameRow[]
    if b.query !== nothing
        # The manual comes first when a title or heading in it matches, unless the query is
        # exactly a name. Matches in the text of its sections do not put it above names.
        q = lowercase(last(split(b.query, '.')))
        names_first = b.manual_titles == 0 ||
            !isempty(b.results) && lowercase(String(b.results[1].name)) == q ||
            !isempty(b.unloaded_hits) && lowercase(last(split(b.unloaded_hits[1][1], '.'))) == q
        names_first && add_name_hits!(rows, b)
        if !isempty(b.manual_hits)
            push!(rows, NameRow(:header, nothing, :manual_hits, length(b.manual_hits)))
            if !(:manual_hits in b.collapsed)
                for (i, h) in enumerate(b.manual_hits)
                    push!(rows, NameRow(:hit, nothing, :manual_hits, i, h))
                end
            end
        end
        names_first || add_name_hits!(rows, b)
        if !isempty(b.text_results)
            push!(rows, NameRow(:header, nothing, :text_hits, length(b.text_results)))
            :text_hits in b.collapsed || append!(rows, (NameRow(:entry, e, :text_hits, 0) for e in b.text_results))
        end
        # what was left out of every group
        b.hidden > 0 && push!(rows, NameRow(:more, nothing, :none, b.hidden))
    elseif on_start(b)
        push!(rows, NameRow(:about, nothing, :none, 0))
        for k in eachindex(START_SECTIONS)
            push!(rows, NameRow(:heading, nothing, :none, k))
        end
    elseif side_unloaded(b) !== nothing
        push!(rows, NameRow(:about, nothing, :none, 0))
        for r in unloaded_rows(b.cat, side_unloaded(b))
            (r.kind === :header || !(r.group in b.collapsed)) && push!(rows, r)
        end
    elseif side_row(b) !== nothing && side_row(b).role === :pkgdocs
        # Pkg's manual lists its pages, each of which unfolds to its headings.
        push!(rows, NameRow(:about, nothing, :none, 0))
        for (j, p) in enumerate(pkg_pages(b))
            at = ManualHit(p.path, "", 0)
            push!(rows, NameRow(:page, nothing, :none, j, at))
            Symbol(p.path) in b.expanded || continue
            for (k, h) in enumerate(page_headings(b.cat, p.path))
                k == 1 && h.level == 1 && continue # the title
                push!(rows, NameRow(:heading, nothing, :none, k, at))
            end
        end
    elseif side_page(b) !== nothing
        # A page of the manual lists its headings, by their place on the page.
        push!(rows, NameRow(:about, nothing, :none, 0))
        for (k, h) in enumerate(page_headings(b.cat, side_page(b).path))
            k == 1 && h.level == 1 && continue # the title
            push!(rows, NameRow(:heading, nothing, :none, k))
        end
    else
        push!(rows, NameRow(:about, nothing, :none, 0))
        # The pages of the package's manual come before its names.
        pages = package_docs(b.cat, b.mod).pages
        isempty(pages) || push!(rows, NameRow(:header, nothing, :manual, length(pages)))
        if !(:manual in b.collapsed)
            for (j, p) in enumerate(pages)
                push!(rows, NameRow(:pkgpage, nothing, :manual, j, ManualHit(p.path, "", 0)))
            end
        end
        entries = module_entries(b.cat, b.mod)
        for k in KINDS
            n = 0
            for e in entries
                e.kind === k && (b.internal || (e.vis !== :internal && !e.deprecated)) && (n += 1)
            end
            n == 0 && continue
            push!(rows, NameRow(:header, nothing, k, n))
            k in b.collapsed && continue
            for e in entries
                e.kind === k && (b.internal || (e.vis !== :internal && !e.deprecated)) || continue
                push!(rows, NameRow(:entry, e, k, 0))
            end
        end
    end
    b.name_rows = rows
    b.names.cursor = clamp(b.names.cursor, 1, max(1, length(rows)))
end

# The names a search finds, under a heading when the manual has results too.
function add_name_hits!(rows::Vector{NameRow}, b::Browser)
    names = NameRow[NameRow(:entry, e, e.kind, 0) for e in b.results]
    unloaded = NameRow[NameRow(:unloaded, nothing, :name_hits, 0, nothing, LoadTarget(id, name))
                       for (name, id) in b.unloaded_hits]
    # The names of packages that are not loaded come after the others, but for one that is
    # exactly the query when no loaded name is.
    q = lowercase(last(split(b.query, '.')))
    exact(r) = lowercase(String(r.kind === :entry ? r.entry.name : last(split(r.target.then, '.')))) == q
    k = isempty(names) || !exact(names[1]) ? count(exact, unloaded) : 0
    hits = [unloaded[1:k]; names; unloaded[k+1:end]]
    others = !isempty(b.manual_hits) || !isempty(b.text_results)
    others && !isempty(hits) && push!(rows, NameRow(:header, nothing, :name_hits, length(hits)))
    (!others || !(:name_hits in b.collapsed)) && append!(rows, hits)
end

side_row(b::Browser) = get(b.side_rows, b.side.cursor, nothing)

# The selected package row when it is a section heading or a package that is not loaded.
# The names pane then shows nothing, rather than the names of the last module shown.
function side_placeholder(b::Browser)
    b.query === nothing && b.source === :side || return nothing
    row = side_row(b)
    # a package that is not loaded has a row saying so, and what its source documents
    (row === nothing || row.pkg !== nothing || row.page !== nothing || row.role === :start ||
     row.unloaded !== nothing) && return nothing
    return row
end

# The package that is not loaded picked in the sidebar, or `nothing`.
function side_unloaded(b::Browser)
    b.query === nothing || return nothing
    row = side_row(b)
    return row === nothing ? nothing : row.unloaded
end

# The pages of the manual and the names that the source of a package that is not loaded
# documents, as rows of the names pane.
function unloaded_rows(cat::Catalog, id::PkgId)
    rows = NameRow[]
    pages = unloaded_docs(cat, id).pages
    isempty(pages) || push!(rows, NameRow(:header, nothing, :manual, length(pages)))
    for (j, p) in enumerate(pages)
        push!(rows, NameRow(:pkgpage, nothing, :manual, j, ManualHit(p.path, "", 0)))
    end
    names = unloaded_package_names(cat, id)
    isempty(names) || push!(rows, NameRow(:header, nothing, :name_hits, length(names)))
    for n in names
        push!(rows, NameRow(:unloaded, nothing, :name_hits, 0, nothing, LoadTarget(id, n)))
    end
    return rows
end

# Whether the start page is picked in the sidebar.
function on_start(b::Browser)
    row = side_row(b)
    return row !== nothing && row.role === :start
end

# The manual page picked in the sidebar.
function side_page(b::Browser)
    row = side_row(b)
    row === nothing && return nothing
    # For Pkg's manual, the names pane picks the page.
    if row.role === :pkgdocs && b.query === nothing
        r = name_row(b)
        i = r === nothing || r.hit === nothing ? nothing : manual_page_of(b.cat, r.hit.path)
        i === nothing || return b.cat.manual[i]
    end
    return row.page
end
name_row(b::Browser) = get(b.name_rows, b.names.cursor, nothing)

# Make the names pane follow the package picked in the sidebar.
function sync_side!(b::Browser)
    row = side_row(b)
    if row !== nothing && row.pkg !== nothing && b.mod !== row.pkg.mod
        b.mod = row.pkg.mod
        b.names = ListState(1, 0)
        b.collapsed = Set{Symbol}()
    end
    row !== nothing && (row.page !== nothing || row.role === :start) && (b.names = ListState(1, 0))
    refresh_names!(b)
end

# Unfold what section `role` is in, so that its heading is listed, and with `open`, the section too.
function unfold_to!(b::Browser, role::Symbol; open::Bool=false)
    is_block(role) && !open && return
    role === :pkgdocs && (role = :stdlibdocs) # Pkg's manual is a row of the standard libraries
    sections = Symbol[role in BLOCKS.docs ? :docs : :code]
    role === :indirect && push!(sections, :direct)
    open && push!(sections, role)
    all(in(b.expanded), sections) && return
    union!(b.expanded, sections)
    refresh_side!(b)
end

function select_package!(b::Browser, m::Module)
    p = package_of(b.cat, m)
    p === nothing && return
    section = package_section(p)
    unfold_to!(b, section; open=true)
    i = findfirst(r -> r.pkg !== nothing && r.pkg.mod === p.mod && r.role === section, b.side_rows)
    i === nothing && return
    b.side.cursor = i
    reveal!(b.side, content_rows(b))
end

# Scroll a list so that its cursor is on screen. The first `offset` rows are not scrolled.
function reveal!(ls::ListState, n::Int, offset::Int=0)
    pos = ls.cursor - offset
    pos < 1 && return ls
    pos <= ls.scroll && (ls.scroll = pos - 1)
    pos > ls.scroll + n && (ls.scroll = pos - n)
    return ls
end

# The names pane shows its first row, the module itself, as its title, outside the list.
names_offset(b::Browser) = !isempty(b.name_rows) && b.name_rows[1].kind === :about ? 1 : 0
list_offset(b::Browser, pane::Symbol) = pane === :names ? names_offset(b) : 0

# The cursor and scroll of the list in `pane`, the sidebar or the names, and how many rows it has.
list_state(b::Browser, pane::Symbol) = pane === :side ? b.side : b.names
list_length(b::Browser, pane::Symbol) = pane === :side ? length(b.side_rows) : length(b.name_rows)

## Navigation ##

snapshot(b::Browser) = Snapshot(b.mod, b.focus, b.source, row_key(side_row(b)), row_key(name_row(b)),
                                b.doc_scroll, b.override, b.query, b.internal, b.searchmode, b.link,
                                key_title(b, current_key(b)))

row_key(::Nothing) = nothing
row_key(r::SideRow) = (r.role, r.pkg === nothing ? nothing : r.pkg.mod, r.unloaded,
                       r.page === nothing ? nothing : r.page.path)
row_key(r::NameRow) = r.entry !== nothing ? (r.entry.mod, r.entry.name) :
    r.hit !== nothing && r.kind !== :hit ? (r.kind, r.hit.path, r.count) : (r.kind, r.group, r.count)

function restore!(b::Browser, s::Snapshot)
    b.mod, b.focus, b.source, b.override, b.internal = s.mod, s.focus, s.source, s.override, s.internal
    b.query = s.query
    b.typing = false
    b.searchmode = s.searchmode
    run_search!(b)
    refresh_side!(b)
    i = findfirst(r -> row_key(r) == s.side, b.side_rows)
    if i === nothing && s.side !== nothing
        # The row was folded away since.
        unfold_to!(b, s.side[1]; open=true)
        i = findfirst(r -> row_key(r) == s.side, b.side_rows)
    end
    i === nothing || (b.side.cursor = i)
    refresh_names!(b)
    i = findfirst(r -> row_key(r) == s.names, b.name_rows)
    b.names.cursor = something(i, 1)
    reveal!(b.side, content_rows(b))
    reveal!(b.names, list_rows(b, :names), names_offset(b))
    b.doc_key = current_key(b)
    b.doc_scroll = s.doc_scroll
    # Select the link again, which is often the one that was followed, to show where we were.
    b.link = s.link
end

function navigate!(f, b::Browser)
    push!(b.back, snapshot(b))
    length(b.back) > 200 && popfirst!(b.back)
    empty!(b.forward)
    f()
end

function go_back!(b::Browser)
    isempty(b.back) && return (b.status = "Nothing to go back to"; true)
    push!(b.forward, snapshot(b))
    s = pop!(b.back)
    restore!(b, s)
    b.status = "Back to " * s.title
    return true
end

function go_forward!(b::Browser)
    isempty(b.forward) && return (b.status = "Nothing to go forward to"; true)
    push!(b.back, snapshot(b))
    s = pop!(b.forward)
    restore!(b, s)
    b.status = "Forward to " * s.title
    return true
end

function close_search!(b::Browser)
    b.query = nothing
    b.typing = false
    b.results = NameEntry[] # the list may be one that the catalog keeps
    empty!(b.manual_hits)
    b.hidden = 0
    refresh_names!(b)
end

"""
    show_module!(b, m; entry=nothing)

Show module `m` in the names pane, with the row for name `entry` selected.
"""
function show_module!(b::Browser, m::Module; entry::Union{Nothing,Symbol}=nothing)
    b.query === nothing || close_search!(b)
    if b.mod !== m
        b.mod = m
        b.collapsed = Set{Symbol}()
    end
    b.override = nothing
    b.source = :names
    select_package!(b, m)
    refresh_names!(b)
    b.names = ListState(1, 0)
    entry === nothing && return
    find(b) = findfirst(r -> r.entry !== nothing && r.entry.name === entry, b.name_rows)
    # The name may be in a folded group.
    for e in module_entries(b.cat, m)
        e.name === entry && e.kind in b.collapsed || continue
        delete!(b.collapsed, e.kind)
        refresh_names!(b)
    end
    i = find(b)
    if i === nothing && !b.internal
        b.internal = true
        refresh_names!(b)
        i = find(b)
        if i === nothing
            b.internal = false # it is not listed at all, so showing internals does not help
            refresh_names!(b)
        else
            b.status = "Showing internal names"
        end
    end
    if i === nothing
        e = @attempt classify(b.cat, m, entry)
        b.override = something(e, ModuleTarget(m))
    else
        b.names.cursor = i
        b.names.scroll = max(0, i - names_offset(b) - list_rows(b, :names) ÷ 3)
    end
end

function follow!(b::Browser, t::Target)
    if t isa AnchorTarget
        p = current_page(b)
        t.heading in eachindex(p.headings) || return
        b.doc_scroll = p.headings[t.heading] - 1
        b.mark = p.headings[t.heading]
        b.doc_line = b.mark
        b.focus = :doc
        b.link = 0
    elseif t isa ToggleTarget
        t.flag === :tip ? next_tip!(b, 1) : t.flag === :tip_back ? next_tip!(b, -1) :
            t.flag === :download ? download_manual!(b) : t.flag === :fetch_docs ? fetch_docs!(b) :
            toggle_flag!(b, t.flag)
    elseif t isa CodeTarget
        n = count(==('\n'), t.code) + 1
        how = COPY[](b, t.code)
        b.status = "Copied $n line$(n == 1 ? "" : "s") of code $how" * (t.julia ? " · y on the code puts it at the prompt" : "")
    elseif t isa URLTarget
        open_url(b, t.url)
    elseif t isa LoadTarget
        load_package!(b, t.id; then=t.then)
    elseif t isa SourceTarget
        edit_source!(b, t)
    elseif t isa ManualTarget
        open_manual!(b, t)
    elseif t isa SectionTarget
        unfold_to!(b, t.role)
        i = findfirst(r -> is_header(r) && r.role === t.role, b.side_rows)
        i === nothing && return
        navigate!(b) do
            b.side.cursor = i
            b.source = :side
            b.focus = :side
        end
    else
        navigate!(b) do
            b.focus = :doc
            if t isa ModuleTarget
                show_module!(b, t.mod)
            else
                v = getglobal(t.mod, t.name)
                if is_submodule(t.mod, v)
                    show_module!(b, v)
                else
                    show_module!(b, t.mod; entry=t.name)
                end
            end
        end
    end
end

function open_entry!(b::Browser, e::NameEntry)
    if e.kind === :module
        val = entry_value(e)
        val isa Module || return
        navigate!(b) do
            b.focus = :names
            show_module!(b, val)
        end
    else
        navigate!(b) do
            b.focus = :doc
            show_module!(b, e.mod; entry=e.name)
        end
    end
end

function current_key(b::Browser)
    b.help && return :help
    b.override === nothing || return b.override
    if b.source === :side
        row = side_row(b)
        row === nothing && return ModuleTarget(b.mod)
        row.role === :start && return :start
        row.unloaded === nothing || return LoadTarget(row.unloaded)
        row.page === nothing || return ManualTarget(side_page(b).path, "")
        return row.pkg === nothing ? SectionTarget(row.role) : ModuleTarget(row.pkg.mod)
    end
    b.query === nothing && on_start(b) && return :start
    p = b.query === nothing ? side_page(b) : nothing
    p === nothing || return ManualTarget(p.path, "")
    row = name_row(b)
    row !== nothing && row.kind in (:hit, :pkgpage) && return ManualTarget(row.hit.path, "")
    row !== nothing && row.kind === :entry && return row.entry
    row !== nothing && row.kind === :unloaded && return row.target
    row !== nothing && row.kind === :about && side_unloaded(b) !== nothing && return LoadTarget(side_unloaded(b))
    # a search's group heading, or a search with no results, shows nothing
    b.query === nothing || return :none
    return ModuleTarget(b.mod)
end

## Side effects that leave the browser ##

function web_browser(url::String)
    # On Windows, `cmd /c start` would run whatever follows an `&` in the URL as a command.
    cmd = Sys.isapple() ? `open $url` :
        Sys.iswindows() ? `rundll32 url.dll,FileProtocolHandler $url` : `xdg-open $url`
    run(pipeline(cmd; stdin=devnull, stdout=devnull, stderr=devnull); wait=false)
end

# How links leave the browser. Tests replace these so nothing is launched.
const URL_OPENER = Ref{Any}(web_browser)
const EDITOR = Ref{Any}(InteractiveUtils.edit)

function open_url(b::Browser, url::String)
    # A link in a docstring could name a local file, which the system would run or open.
    occursin(r"^(https?|mailto):"i, url) || return (b.status = "Not a web link: " * url; nothing)
    if URL_OPENER[] === web_browser && haskey(ENV, "SSH_CONNECTION")
        # A web browser would open on the remote machine, so hand the link over instead.
        how = COPY[](b, url)
        b.status = "Copied $url $how"
        return
    end
    try
        URL_OPENER[](url)
        b.status = "Opened " * url
    catch err
        err isa InterruptException && rethrow()
        b.status = "Could not open " * url
    end
end

function edit_source!(b::Browser, t::SourceTarget)
    isfile(t.file) || return (b.status = "Source file not found: " * Base.contractuser(t.file); nothing)
    suspend(b) do
        EDITOR[](t.file, max(t.line, 1))
    end
end

# Run `f` on the normal screen. Returns whether it succeeded.
function suspend(f, b::Browser)
    leave_screen(b)
    try
        f()
        return true
    catch err
        err isa InterruptException && rethrow()
        b.status = "Error: " * first_line(err)
        return false
    finally
        enter_screen(b)
    end
end

"""
    load_package!(b, id; then = "")

Load the package `id` with `import` in `Main`, in a task of its own, and show it once it is
loaded, or the name `then` in it. Meanwhile what loading prints, such as precompilation, shows in a panel above the
footer, and the browser can still be used.
"""
function load_package!(b::Browser, id::PkgId; then::String="")
    # The precompile workload must not load whatever the active project depends on.
    Base.generating_output() && return
    loading(b) && return (b.status = "Already " * lowercasefirst(b.loading); nothing)
    b.console = ["julia> import " * id.name]
    start = current_key(b)
    # Loading prints nothing while it precompiles, which can take minutes, so say so.
    precompiled = dynamic(Base.isprecompiled)(id)::Bool
    what = Ref((precompiled ? "Loading " : "Precompiling ") * id.name)
    function load()
        # Precompiling first, as the import would, runs in other processes, and the browser
        # keeps working meanwhile. Without this internal function the import does it.
        precompiled || try
            dynamic(Base.Precompilation.precompilepkgs)([id]; _from_loading=true, ignore_loaded=false)
        catch err
            err isa MethodError || rethrow()
        end
        # Loading into the session holds locks that the browser's own calls wait for, so it
        # stops responding until the package is loaded. It says so before it does.
        @lock b.lock begin
            what[] = "Loading " * id.name
            b.modal = what[] * "…"
            b.live && in_world(draw, b)
        end
        import_package(id)
    end
    function done(ok)
        ok || return
        b.console = nothing
        # Go to the package, or to the name asked for in it, only if nothing else was opened
        # while it loaded.
        go = current_key(b) == LoadTarget(id)
        stayed = current_key(b) == start
        # The package's bindings are only visible in the latest world.
        b.world = Base.get_world_counter()
        in_world(show_loaded!, b, id, go && isempty(then))
        isempty(then) || !stayed || in_world(open_name!, b, then)
    end
    in_console(load, done, b, what)
    return
end

loading(b::Browser) = b.load_task !== nothing && !istaskdone(b.load_task)

in_world(f, b::Browser, args...) = Base.invoke_in_world(b.world, f, b, args...)

# A package being loaded prints to the panel until it is done, so the browser stays open.
function stay_open!(b::Browser)
    loading(b) || return
    b.quit = false
    b.result = nothing
    b.status = b.loading * " The browser can close once it is done."
end

# Run `f` in a task, with what it prints shown in the console panel as it comes, and then
# `done(ok)` with the browser's lock held. Output is redirected for the whole process, which is
# why only one runs at a time and the browser does not close while it runs.
function in_console(f, done, b::Browser, what::Ref{String})
    t0 = time()
    b.loading = what[] * "…"
    pipe = Pipe()
    Base.link_pipe!(pipe; reader_supports_async=true, writer_supports_async=true)
    redraw() = try
        b.live && in_world(draw, b)
    catch
    end
    # Started here, on the browser's thread, so that they run while `f` keeps its own busy.
    reader = @async for line in eachline(pipe)
        @lock b.lock (push!(b.console, console_text(line)); redraw())
    end
    clock = Timer(1; interval=1) do _
        @lock b.lock (b.loading = string(what[], "… ", round(Int, time() - t0), " s"); redraw())
    end
    t = @task begin
        ok = false
        try
            redirect_stdio(stdout=pipe, stderr=pipe) do
                Base.CoreLogging.with_logger(f, Base.CoreLogging.SimpleLogger(pipe))
            end
            ok = true
        catch err
            @lock b.lock begin
                b.status = "Error: " * first_line(err)
                append!(b.console, console_text.(split(sprint(showerror, err), '\n')))
            end
        finally
            close(clock)
            close(pipe.in)
            wait(reader)
            @lock b.lock begin
                b.loading = ""
                b.modal = ""
                try
                    done(ok)
                catch err
                    b.status = "Error: " * first_line(err)
                end
                redraw()
            end
        end
    end
    b.load_task = t
    b.loads === nothing ? schedule(t) : put!(b.loads, t)
    return
end

# A line of output as plain text, as a terminal would leave it after any carriage return.
console_text(line::AbstractString) = replace(last(split(line, '\r')), r"\e\[[0-9;?]*[A-Za-z]" => "")

function open_name!(b::Browser, name::String)
    t = resolve_ref(name, Main, b.cat)
    t === nothing ? (b.status = "No documentation for " * name) : follow!(b, t)
end

function show_loaded!(b::Browser, id::PkgId, go::Bool=true)
    b.cat = Catalog()
    empty!(b.pages)
    refresh_side!(b)
    b.status = "Loaded " * id.name
    go || return
    m = Base.root_module(id)
    navigate!(b) do
        b.focus = :side
        show_module!(b, m)
        b.source = :side
    end
    b.status = "Loaded " * id.name
end

page_source(b::Browser) = current_page(b).source

"""
    source_of(b, x) -> Union{SourceTarget, Nothing}

Where `x` is defined: a link target, a name, a module or a package that is not loaded.
For a name this is its docstring, or else its first method.
"""
function source_of(b::Browser, x)
    x isa SourceTarget && return x
    x isa NameTarget && return source_of(b, classify(b.cat, x.mod, x.name))
    x isa ModuleTarget && return page(b, x, doc_width(b)).source
    x isa PkgEntry && return source_of(b, ModuleTarget(x.mod))
    if x isa LoadTarget || x isa PkgId
        id = x isa LoadTarget ? x.id : x
        path = dynamic(Base.locate_package)(id)::Union{Nothing,String}
        return path === nothing ? nothing : SourceTarget(path, 1)
    end
    x isa NameEntry || return nothing
    is_module_entry(x) && return source_of(b, ModuleTarget(x.mod))
    for d in doc_results(Binding(x.mod, x.name))
        t = source_target(d)
        t === nothing || return t
    end
    val = entry_value(x)
    val isa Module && return source_of(b, ModuleTarget(val))
    if val isa Function || val isa Type
        ms = methods(val)
        isempty(ms) || return method_target(first(ms))
    end
    return nothing
end

# The thing that a screen region shows, for finding its source.
function hit_subject(b::Browser, action)
    action isa Tuple || return nothing
    kind = first(action)::Symbol
    if kind === :spot
        p = current_page(b)
        k = action[2]::Int
        return k in eachindex(p.spots) ? p.spots[k].target : nothing
    elseif kind === :side
        row = get(b.side_rows, action[2]::Int, nothing)
        row === nothing && return nothing
        row.page === nothing || return SourceTarget(row.page.path, 1)
        return row.unloaded !== nothing ? row.unloaded : row.pkg
    elseif kind === :names
        row = get(b.name_rows, action[2]::Int, nothing)
        row === nothing && return nothing
        row.kind === :entry && return row.entry
        row.kind === :hit && return SourceTarget(row.hit.path, hit_line(b.cat, row.hit))
        row.kind === :pkgpage && return SourceTarget(row.hit.path, 1)
        row.kind === :unloaded && return row.target
        p = side_page(b)
        return p === nothing ? ModuleTarget(b.mod) : SourceTarget(p.path, 1)
    elseif kind === :load
        return action[2]
    elseif kind === :card
        b.card === nothing && return nothing
        subject = b.card[2]
        return subject isa ManualTarget ? SourceTarget(subject.path, 1) : subject
    elseif kind === :crumb
        return ModuleTarget(action[2])
    end
    return nothing
end

# The selected link, or else the selected row of the focused list.
function selected_subject(b::Browser)
    if b.focus === :doc
        p = current_page(b)
        b.link in eachindex(p.spots) && return p.spots[b.link].target
        return nothing
    end
    return hit_subject(b, (b.focus, list_state(b, b.focus).cursor))
end

function edit_subject!(b::Browser, x)
    src = x === nothing ? nothing : source_of(b, x)
    src === nothing ? (b.status = "No source location for that") : edit_source!(b, src)
    return true
end

function current_name(b::Browser)
    key = current_key(b)
    key isa NameEntry && return qualified_name(key)
    key isa ModuleTarget && return qualified_name(module_entry(b.cat, key.mod))
    return nothing
end

# What the ⧉ of the block of code that line `li` of the page is in copies, or `nothing`.
function code_at(b::Browser, li::Int)
    p = current_page(b)
    i = copy_spot(p, code_block_start(p, li))
    return i === nothing ? nothing : p.spots[i].target::CodeTarget
end

# The first line of the block of code that line `li` is in, or 0.
function code_block_start(p::Page, li::Int)
    li in eachindex(p.lines) && is_code_line(p.lines[li]) || return 0
    while li > 1 && is_code_line(p.lines[li-1])
        li -= 1
    end
    return li
end

# The place that copies the block of code starting at line `start`.
copy_spot(p::Page, start::Int) = findfirst(s -> s.line == start && s.target isa CodeTarget, p.spots)

# The link that ⏎ follows with the cursor on line `li`: one on the line, or else the ⧉ of the
# block of code it is in. Zero for none.
function line_link(p::Page, li::Int)
    i = findfirst(s -> s.line == li && !(s.target isa CodeTarget), p.spots)
    i === nothing || return i
    return something(copy_spot(p, code_block_start(p, li)), 0)
end

## Layout ##

const LAYOUTS = (:auto, :three, :two, :one)

function layout(b::Browser)
    W = b.width
    mode = b.layout
    if mode === :one || W < 60
        return [(b.focus, 1, W)]
    elseif mode === :three || (mode === :auto && W >= 100)
        sw = clamp(W ÷ 5, 18, 28)
        nw = clamp(W ÷ 4, 24, 36)
        return [(:side, 1, sw), (:names, sw + 2, nw), (:doc, sw + nw + 3, W - sw - nw - 2)]
    else
        lw = clamp(W ÷ 3, 20, 32)
        left = b.focus === :side || (b.focus === :doc && b.source === :side) ? :side : :names
        return [(left, 1, lw), (:doc, lw + 2, W - lw - 1)]
    end
end

content_rows(b::Browser) = max(1, b.height - 3)

function doc_width(b::Browser)
    for (pane, _, w) in layout(b)
        pane === :doc && return max(10, w - 1)
    end
    return max(10, b.width - 1)
end

# `pic` if the terminal has taken it, or was sent it and should still answer. The terminal
# reads the picture before whatever is written next, so it is drawn without waiting.
expected(b::Browser, pic::Picture) = pic in b.pictures || !b.gave_up && pic in b.awaited ? pic : nothing

page_flags(b::Browser, key) = dynamic(get)(b.flags, key, Set{Symbol}())::Set{Symbol}
# The same set, kept for the page, so that changes to it stay.
page_flags!(b::Browser, @nospecialize(key)) = dynamic(get!)(Set{Symbol}, b.flags, key)::Set{Symbol}

function page(b::Browser, key, width::Int)
    flags = page_flags(b, key)
    p = dynamic(get!)(b.pages, (key, width, sort!(collect(flags)))) do
        try
            key isa NameEntry ? entry_page(b.cat, key, width, flags) :
            key isa ModuleTarget ? module_page(b.cat, key.mod, width) :
            key isa SectionTarget ? section_page(b.cat, key.role, width) :
            key isa LoadTarget ? unloaded_page(b.cat, key.id, width, key.then) :
            key isa ManualTarget ? manual_page(b.cat, key.path, width) :
            key === :start ? start_page(b.cat, width, b.tips[b.tip], b.tip, expected(b, logo_picture(b.cell))) :
            key === :help ? help_page(b.cat, width) : Page(PageBuilder(width))
        catch err
            err isa InterruptException && rethrow()
            pb = PageBuilder(width)
            addline!(pb)
            addline!(pb, "  ", ("Could not show this page:", :error))
            for line in split(sprint(showerror, err), '\n')
                addline!(pb, "  ", line)
            end
            Page(pb)
        end
    end
    return p::Page
end

# The page that the documentation pane shows.
current_page(b::Browser) = page(b, current_key(b), doc_width(b))

## Drawing ##

function fit(s::AnnotatedString{String}, w::Int)
    w <= 0 && return AnnotatedString("")
    str = String(s)
    if any(c -> c < ' ', str)
        str = map(c -> c < ' ' ? ' ' : c, str)
        s = AnnotatedString(str, annotations(s))
    end
    total = textwidth(str)
    total <= w && return concat(s, ' '^(w - total))
    used = 0
    last = 0
    for (i, c) in pairs(str)
        cw = textwidth(c)
        used + cw > w - 1 && break
        used += cw
        last = i
    end
    head = last == 0 ? AnnotatedString("") : s[1:last]
    return concat(head, styled("…", :REPL_DocBrowser_dim), ' '^(w - 1 - used))
end
fit(s::AbstractString, w::Int) = fit(AnnotatedString(String(s)), w)

# `s` with `face` beneath the faces it already has.
under_face(s::AnnotatedString{String}, face::Symbol) =
    AnnotatedString(String(s), pushfirst!(copy(annotations(s)), (region=1:ncodeunits(s), label=:face, value=face)))

# Apply `face` to the display columns `cols` of `s`.
function face_cols!(s::AnnotatedString, cols::UnitRange{Int}, face)
    str = String(s)
    col = 1
    b1 = b2 = 0
    for (i, c) in pairs(str)
        col > last(cols) && break
        if col >= first(cols)
            b1 == 0 && (b1 = i)
            b2 = i + ncodeunits(c) - 1
        end
        col += textwidth(c)
    end
    b1 > 0 && face!(s, b1:b2, face)
    return s
end

copy_line(s::AnnotatedString{String}) = AnnotatedString(String(s), copy(annotations(s)))

"""
    RowBuilder

Builds one screen row from segments, recording where clickable segments land.
"""
mutable struct RowBuilder
    b::Browser
    row::Int
    col::Int
    parts::Vector{AnnotatedString{String}}
end
RowBuilder(b::Browser, row::Int, col::Int) = RowBuilder(b, row, col, AnnotatedString{String}[])

function put_seg!(rb::RowBuilder, text, face=nothing, action=nothing)
    s = styled(text, face)
    w = textwidth(String(s))
    if action !== nothing && w > 0
        push!(rb.b.hits, Hit(rb.row, rb.col:rb.col+w-1, action))
        rb.b.hover == action && face!(s, :REPL_DocBrowser_hover)
    end
    push!(rb.parts, s)
    rb.col += w
    return rb
end

width(rb::RowBuilder) = sum(p -> textwidth(String(p)), rb.parts; init=0)
build(rb::RowBuilder) = isempty(rb.parts) ? AnnotatedString("") : concat(rb.parts...)

function hint_segments(b::Browser)
    narrow = b.width < 100 ? [("w", "layout")] : Tuple{String,String}[]
    if b.console !== nothing && isempty(b.loading)
        return [("any key", "close")]
    elseif b.help
        return [("esc", "close")]
    elseif b.typing
        return [("↑↓", "choose"), ("⏎", "open"), ("^T", NEXT_MODE_LABEL[b.searchmode]),
                ("^A", b.indirect ? "direct only" : "+indirect"), ("⇥", "results"), ("esc", "cancel")]
    elseif b.focus === :doc
        p = current_page(b)
        # On code, what can be done with it comes first, as its ⧉ says little by itself.
        code = code_at(b, b.doc_line)
        oncode = code !== nothing
        hints = !oncode ? [("↑↓", "scroll"), ("⇥", "next link"), ("⏎", "follow"), ("[ ]", "back/forward")] :
            code.julia ? [("⏎", "copy code"), ("y", "send it to prompt"), ("↑↓", "scroll"), ("⇥", "next link")] :
            [("⏎", "copy code"), ("↑↓", "scroll"), ("⇥", "next link")]
        isempty(p.headings) || push!(hints, ("{ }", "headings"))
        any(s -> s.target == ToggleTarget(:extended), p.spots) && push!(hints, ("x", "extended"))
        current_key(b) === :start && push!(hints, ("t T", "tips"))
        return vcat(narrow, hints, [("/", "search")], oncode ? Tuple{String,String}[] : [("y", "send to prompt")],
                    [("e", "source"), ("c", "link")])
    else
        # On a narrow terminal the layout matters most, so it comes first.
        return vcat(narrow, [("↑↓", "move"), ("⏎", "open"), ("←→", "panes"), ("/", "search"),
                     ("i", b.internal ? "hide internal" : "internal"), ("[ ]", "back/forward"),
                     ("y", "send to prompt")])
    end
end

const HINT_KEYS = Dict("↑↓" => nothing, "any key" => nothing, "←→" => nothing, "⏎" => KeyEvent(:enter),
                       "⇥" => KeyEvent(:tab), "⌫" => KeyEvent(:backspace),
                       "esc" => KeyEvent(:escape), "{ }" => KeyEvent('}'),
                       "^T" => KeyEvent('t', CTRL), "^A" => KeyEvent('a', CTRL))
hint_key(k::String) = haskey(HINT_KEYS, k) ? HINT_KEYS[k] : KeyEvent(first(k))

const TIP = "Tip: click anything · drag to copy · right-click opens its source · ? lists every key"
const FIRST_OPEN = Ref(true)

"""
    describe(b, action) -> Union{String, Nothing}

What clicking a region of the screen does, for the status line.
"""
function describe(b::Browser, action)
    action isa Tuple || return nothing
    kind = first(action)::Symbol
    if kind === :spot
        p = current_page(b)
        k = action[2]::Int
        k in eachindex(p.spots) || return nothing
        return describe_target(b, p, p.spots[k].target)
    elseif kind === :side
        row = get(b.side_rows, action[2]::Int, nothing)
        row === nothing && return nothing
        row.unloaded === nothing || return "↓ $(row.unloaded.name) is not loaded · ⏎ load it"
        row.role === :pkgdocs && return "Pkg's manual · ⏎ its pages"
        row.page === nothing || return "$(row.page.title) · ⏎ its sections · right-click: source"
        row.role === :start && return "where to begin: the manual, the keys, and your project"
        row.pkg === nothing && return "⏎ fold or unfold this section"
        return "$(row.pkg.id.name) · ⏎ open · right-click: source"
    elseif kind === :names
        row = get(b.name_rows, action[2]::Int, nothing)
        row === nothing && return nothing
        row.kind === :header && return "⏎ fold or unfold this group"
        row.kind === :heading && return "↓ jumps to this section of the page"
        row.kind === :page && return "this page · ⏎ show or hide its sections"
        row.kind === :pkgpage && return "a page of $(display_name(b.mod))'s manual · ⏎ read · right-click: source"
        row.kind === :hit && return "the manual: $(manual_title(b.cat, row.hit.path)) · ⏎ open"
        row.kind === :more && return "⏎ search indirect dependencies too (^A)"
        row.kind === :unloaded && return "$(row.target.then) · ⏎ load $(row.target.id.name) and read it"
        row.kind === :about && side_page(b) !== nothing && return "the top of the page"
        row.kind === :about && return "the documentation of $(display_name(b.mod))"
        e = row.entry::NameEntry
        open = e.kind === :module ? "⏎ open the module" : "⏎ read"
        return "$(display_name(e)) · $open · right-click: source"
    elseif kind === :load
        return "↓ runs import $(action[2].name), then shows its documentation"
    elseif kind === :crumb
        return "→ $(display_name(action[2]))"
    elseif kind === :back
        return isempty(b.back) ? "◀ nothing to go back to" : "◀ back to $(last(b.back).title) ([ or ⌫)"
    elseif kind === :forward
        return isempty(b.forward) ? "▶ nothing to go forward to" : "▶ forward to $(last(b.forward).title) (])"
    elseif kind === :copylink
        return "⧉ copies a link to this place, to paste at the julia> prompt (c)"
    elseif kind === :search
        return "/ search " * MODE_DESCRIPTION[b.searchmode]
    elseif kind === :toggle_text
        return "⇄ search " * MODE_DESCRIPTION[next_mode(b.searchmode)] * " instead (^T)"
    elseif kind === :project
        proj = Base.active_project()
        return proj === nothing ? nothing : "the active project: " * Base.contractuser(proj)
    elseif kind === :help
        return "? every key and mouse action"
    elseif kind === :quit
        return "✕ close the browser (q)"
    elseif kind === :scrollbar
        return "click or drag to scroll"
    end
    return nothing
end

function describe_target(b::Browser, p::Page, t)
    if t isa NameTarget
        return "→ $(display_name(t.mod)).$(t.name) · ⏎ follow · right-click: source"
    elseif t isa ModuleTarget
        return "→ $(display_name(t.mod)) · ⏎ follow · right-click: source"
    elseif t isa URLTarget
        return "↗ opens $(t.url) in your web browser"
    elseif t isa SourceTarget
        return "✎ opens $(source_label(t)) in your editor"
    elseif t isa LoadTarget
        return "↓ runs import $(t.id.name), then shows its documentation"
    elseif t isa CodeTarget
        n = count(==('\n'), t.code) + 1
        return "⧉ copies $n line$(n == 1 ? "" : "s") of code" * (t.julia ? " · y on the code puts it at the prompt" : "")
    elseif t isa ManualTarget
        i = manual_page_of(b.cat, t.path)
        title = i === nothing ? basename(dirname(dirname(dirname(t.path)))) : b.cat.manual[i].title
        return "→ the manual: $(title)$(isempty(t.anchor) ? "" : ", “" * t.anchor * "”") · ⏎ follow"
    elseif t isa AnchorTarget
        t.heading in eachindex(p.headings) || return nothing
        return "↓ jumps to “$(strip(String(p.lines[p.headings[t.heading]])))” ({ } step through headings)"
    elseif t isa ToggleTarget
        t.flag === :extended && return "shows or hides the extended help (x)"
        t.flag === :tip && return "shows the next tip (t)"
        t.flag === :tip_back && return "shows the previous tip (T)"
        t.flag === :download && return "downloads the manual again"
        t.flag === :fetch_docs &&
            return "downloads the package's manual from its repository, at the installed version · DocBrowser.explain_docs says where the browser looked"
        return "finds every method that takes this type; this can take a moment"
    elseif t isa SectionTarget
        return "→ $(getfield(SECTION_TITLES, t.role))"
    end
    return nothing
end

# The line at the left of the footer: a message, else what is under the pointer or
# selected, else the first-open tip.
function footer_message(b::Browser)
    isempty(b.status) || return b.status
    d = describe(b, b.hover)
    d === nothing || return d
    if b.focus === :doc && b.link != 0
        d = describe(b, (:spot, b.link))
        d === nothing || return d
    end
    isempty(b.fetch_note) || return b.fetch_note
    return FIRST_OPEN[] ? TIP : ""
end

function footer_bar(b::Browser)
    rb = RowBuilder(b, b.height, 1)
    put_seg!(rb, " ")
    msg = footer_message(b)
    if !isempty(msg)
        put_seg!(rb, msg, :REPL_DocBrowser_key)
        put_seg!(rb, "   ")
    end
    # `? help` and `q quit` are always kept, at the end of the hints.
    tail = b.help ? Tuple{String,String}[] : [("?", "help"), ("q", "quit")]
    tailw = sum(h -> textwidth(h[1]) + textwidth(h[2]) + 3, tail; init=0)
    for (key, label) in hint_segments(b)
        width(rb) + textwidth(key) + textwidth(label) + 3 + tailw > b.width && break
        put_hint!(rb, key, label)
    end
    for (key, label) in tail
        put_hint!(rb, key, label)
    end
    return under_face(fit(build(rb), b.width), :REPL_DocBrowser_bar)
end

# What the markers in the list of names mean. Internal names are only explained while they
# are listed, and so are re-exports. A narrow pane gets shorter words, then initials.
function names_legend(b::Browser, w::Int)
    marks = b.color ? Tuple{String,Any}[(" ● ", :REPL_DocBrowser_exported), (" ○ ", :REPL_DocBrowser_public),
                                        (" · ", :REPL_DocBrowser_internal)] :
                      Tuple{String,Any}[(" E ", nothing), (" P ", nothing), (" - ", nothing)]
    words = [("exported", "export"), ("public", "public"), ("internal", "internal")]
    b.internal || (pop!(marks); pop!(words))
    if b.query === nothing && any(r -> r.kind === :entry && reexported_from(r.entry) !== nothing, b.name_rows)
        push!(marks, (" ↗ ", nothing))
        push!(words, ("re-exported", "re-export"))
    end
    local segs
    for form in (first, last, w -> first(first(w), 1))
        segs = Seg[]
        for (m, word) in zip(marks, words)
            push!(segs, Seg(m...), Seg(form(word), :REPL_DocBrowser_dim))
        end
        segs_width(segs) <= w && break
    end
    return segs
end

# The names pane keeps its last row for the legend.
has_legend(b::Browser, pane::Symbol) = pane === :names && side_placeholder(b) === nothing &&
    content_rows(b) > 2 && any(r -> r.kind === :entry, b.name_rows)
list_rows(b::Browser, pane::Symbol) = content_rows(b) - has_legend(b, pane)

function put_hint!(rb::RowBuilder, key::String, label::String)
    action = hint_key(key)
    put_seg!(rb, key, :REPL_DocBrowser_key, action === nothing ? nothing : (:key, action))
    put_seg!(rb, " " * label * "  ", nothing, action === nothing ? nothing : (:key, action))
end

# A piece of a bar, kept in one concrete type so that lists of them compile once.
struct Seg
    text::String
    face::Any
    action::Any
end
Seg(text::String, face=nothing) = Seg(text, face, nothing)

segs_width(segs::Vector{Seg}) = (w = 0; for s in segs; w += textwidth(s.text); end; w)

function put_segs!(rb::RowBuilder, segs::Vector{Seg})
    for s in segs
        put_seg!(rb, s.text, s.face, s.action)
    end
end

# The right of the header. A higher `level` leaves out more, for narrow terminals.
function header_right(b::Browser, level::Int)
    right = Seg[]
    mode = String(b.searchmode)
    if b.query === nothing
        push!(right, Seg(b.searchmode === :all ? " / search " : " / search $mode ", nothing, (:search,)))
    else
        # The field being typed into stands out; once typing stops it is only shaded.
        face = b.typing ? :REPL_DocBrowser_searchbox : :REPL_DocBrowser_unfocused
        q = b.query
        text = b.typing ? string(" ", first(q, b.qcol), "▏", chop(q; head=b.qcol, tail=0)) : string(" ", q, " ")
        pad = level == 0 ? max(0, 22 - textwidth(text)) : 0
        # a search for everything says nothing of what it looks in
        level < 2 && b.searchmode !== :all && push!(right, Seg(" "), Seg(" " * mode * " ⇄ ", face, (:toggle_text,)))
        push!(right, Seg(text * ' '^pad, face, (:search,)))
        found = length(b.results) + length(b.text_results) + length(b.unloaded_hits)
        level == 0 && push!(right, Seg(string(" ", found, " found "), :REPL_DocBrowser_dim))
    end
    push!(right, Seg("  "), Seg("?", :REPL_DocBrowser_key, (:help,)),
          Seg("  "), Seg("✕", :REPL_DocBrowser_key, (:quit,)), Seg(" "))
    return right
end

function header_bar(b::Browser)
    right = header_right(b, 0)
    for level in 1:2
        segs_width(right) < b.width && break
        right = header_right(b, level)
    end
    rw = segs_width(right)
    room = max(0, b.width - rw)
    rb = RowBuilder(b, 1, 1)
    put_seg!(rb, " ")
    mark = expected(b, mark_picture(b.cell))
    if mark === nothing
        put_seg!(rb, "●", :REPL_DocBrowser_logo_red)
        put_seg!(rb, "●", :REPL_DocBrowser_logo_green)
        put_seg!(rb, "●", :REPL_DocBrowser_logo_purple)
    else
        push!(b.placements, Placement(mark, 1, rb.col, 0, 1))
        put_seg!(rb, " "^mark.cols)
    end
    put_seg!(rb, " Julia docs ", :REPL_DocBrowser_title)
    proj = project_label()
    proj === nothing || put_seg!(rb, " ($proj)", :REPL_DocBrowser_dim, (:project,))
    put_seg!(rb, " ")
    put_seg!(rb, "◀ back", isempty(b.back) ? :REPL_DocBrowser_dim : :REPL_DocBrowser_key, (:back,))
    put_seg!(rb, "  ")
    put_seg!(rb, "forward ▶", isempty(b.forward) ? :REPL_DocBrowser_dim : :REPL_DocBrowser_key, (:forward,))
    put_seg!(rb, "  ")
    placeholder = side_placeholder(b)
    if placeholder !== nothing
        # Not the module shown before, which is no longer what is selected.
        put_seg!(rb, placeholder.unloaded === nothing ? getfield(SECTION_TITLES, placeholder.role) :
                 placeholder.unloaded.name, :REPL_DocBrowser_pane_title)
    elseif on_start(b) && b.override === nothing && b.query === nothing
        put_seg!(rb, "Start", :REPL_DocBrowser_pane_title)
    elseif side_page(b) !== nothing && b.override === nothing
        p = side_page(b)
        role = p.role === :pkgdocs ? :stdlibdocs : p.role
        put_seg!(rb, getfield(SECTION_TITLES, role), :REPL_DocBrowser_pane_title, (:section, role))
        put_seg!(rb, " › ", :REPL_DocBrowser_dim)
        p.role === :pkgdocs && put_seg!(rb, "Pkg › ", :REPL_DocBrowser_dim)
        put_seg!(rb, p.title, :REPL_DocBrowser_pane_title)
    else
        for (i, m) in enumerate(module_path(b.mod))
            i > 1 && put_seg!(rb, " › ", :REPL_DocBrowser_dim)
            put_seg!(rb, String(nameof(m)), :REPL_DocBrowser_pane_title, (:crumb, m))
        end
    end
    key = current_key(b)
    if placeholder === nothing && key isa NameEntry && key.mod === b.mod && !is_module_entry(key)
        put_seg!(rb, " › ", :REPL_DocBrowser_dim)
        put_seg!(rb, String(key.name))
    end
    if width(rb) > room
        # Crop the breadcrumbs, so the search box and buttons stay put.
        left = fit(build(rb), room)
        filter!(h -> h.row != 1 || last(h.cols) <= room - 1, b.hits)
        rb = RowBuilder(b, 1, room + 1, [left])
    else
        put_seg!(rb, ' '^(room - width(rb)))
    end
    put_segs!(rb, right)
    return under_face(fit(build(rb), b.width), :REPL_DocBrowser_bar)
end

# `m` and the modules it is inside, outermost first. Following parents rather than looking
# up names keeps working when a module has been replaced or is bound under another name.
function module_path(m::Module)
    path = Module[m]
    while parentmodule(m) !== m
        m = parentmodule(m)
        pushfirst!(path, m)
    end
    return path
end

function list_line(b::Browser, pane::Symbol, i::Int, x::Int, w::Int, row::Int)
    i > list_length(b, pane) && return fit("", w)
    rb = RowBuilder(b, row, x)
    action = (pane, i)
    first_hit = length(b.hits) + 1
    push!(b.hits, Hit(row, x:x+w-1, action))
    if pane === :side
        r = b.side_rows[i]
        if r.role === :start
            put_seg!(rb, " ⌂ ", :REPL_DocBrowser_kind_module, action)
            put_seg!(rb, "Start", :REPL_DocBrowser_pane_title, action)
        elseif r.unloaded !== nothing
            put_seg!(rb, "   ")
            put_seg!(rb, r.unloaded.name, nothing, action)
            room = w - width(rb) - 1
            if room >= 7
                put_seg!(rb, ' '^(room - 6))
                put_seg!(rb, "↓ load", :REPL_DocBrowser_key, (:load, r.unloaded))
            end
        elseif r.page !== nothing
            put_seg!(rb, "   ")
            put_seg!(rb, r.role === :pkgdocs ? "Pkg" : r.page.title, nothing, action)
        elseif r.pkg === nothing
            role = r.role
            chevron = role in b.expanded ? "▾ " : "▸ "
            if is_block(role)
                put_seg!(rb, chevron, :REPL_DocBrowser_dim, action)
                put_seg!(rb, getfield(SIDEBAR_TITLES, role), :REPL_DocBrowser_pane_title, action)
            else
                n = length(section_rows(b, role))
                put_seg!(rb, role === :indirect && has_section(b, :direct) ? "   " : " ")
                put_seg!(rb, chevron, :REPL_DocBrowser_dim, action)
                put_seg!(rb, getfield(SIDEBAR_TITLES, role), :REPL_DocBrowser_section, action)
                status = role === :manual && n == 0 ? manual_status() : :none
                put_seg!(rb, status === :downloading ? " loading…" : status === :failed ? " failed" : " $n",
                         :REPL_DocBrowser_dim, action)
            end
        else
            p = r.pkg
            version = p.version === nothing || p.role === :julia ? "" : string(p.version)
            put_seg!(rb, r.role === :main ? "  " : r.role === :indirect && has_section(b, :direct) ? "     " : "   ")
            put_seg!(rb, p.id.name, isjll(p.id.name) ? :REPL_DocBrowser_dim : nothing, action)
            room = w - width(rb) - 1
            if !isempty(version) && textwidth(version) + 1 <= room
                put_seg!(rb, ' '^(room - textwidth(version)))
                put_seg!(rb, version, :REPL_DocBrowser_dim)
            end
        end
    else
        r = b.name_rows[i]
        if r.kind === :about
            p = b.query === nothing ? side_page(b) : nothing
            pkg = p !== nothing && p.role === :pkgdocs
            id = side_unloaded(b)
            title = on_start(b) ? "Start" : pkg ? "Pkg" : id !== nothing ? id.name : p === nothing ? String(nameof(b.mod)) : p.title
            n = id !== nothing ? "not loaded" : pkg ? "$(count(r -> r.kind === :page, b.name_rows)) pages" :
                p === nothing && !on_start(b) ? "$(count(r -> r.kind === :entry, b.name_rows)) names" :
                "$(length(b.name_rows) - 1) sections"
            put_seg!(rb, " " * title, b.focus === :names ? :REPL_DocBrowser_title : :REPL_DocBrowser_section, action)
            put_seg!(rb, "  " * n, :REPL_DocBrowser_dim, action)
        elseif r.kind === :heading && on_start(b)
            r.count in eachindex(START_SECTIONS) || return fit("", w)
            put_seg!(rb, "  ")
            put_seg!(rb, START_SECTIONS[r.count], :REPL_DocBrowser_pane_title, action)
        elseif r.kind === :page
            p = b.cat.manual[manual_page_of(b.cat, r.hit.path)]
            put_seg!(rb, Symbol(p.path) in b.expanded ? " ▾ " : " ▸ ", :REPL_DocBrowser_dim, action)
            put_seg!(rb, p.title, :REPL_DocBrowser_pane_title, action)
        elseif r.kind === :pkgpage
            id = side_unloaded(b)
            pages = id === nothing ? package_docs(b.cat, b.mod).pages : unloaded_docs(b.cat, id).pages
            r.count in eachindex(pages) || return fit("", w)
            put_seg!(rb, "   ")
            put_seg!(rb, pages[r.count].title, nothing, action)
        elseif r.kind === :heading
            path = r.hit === nothing ? (p = side_page(b); p === nothing ? nothing : p.path) : r.hit.path
            hs = path === nothing ? Heading[] : page_headings(b.cat, path)
            r.count in eachindex(hs) || return fit("", w)
            h = hs[r.count]
            put_seg!(rb, (r.hit === nothing ? "  " : "    ") * "  "^max(0, h.level - 2))
            put_seg!(rb, h.text, h.level <= 2 ? :REPL_DocBrowser_pane_title : nothing, action)
        elseif r.kind === :more
            put_seg!(rb, " + $(r.count) in indirect dependencies (^A)", :REPL_DocBrowser_dim, action)
        elseif r.kind === :unloaded
            t = r.target::LoadTarget
            put_seg!(rb, "   ")
            put_match!(rb, String(chop(t.then; head=length(t.id.name) + 1, tail=0)), nothing, action)
            put_right!(rb, w, " " * t.id.name)
        elseif r.kind === :hit
            # a section of the manual with its page on the right, or a page with its part of the docs
            h = r.hit::ManualHit
            put_seg!(rb, " § ", :REPL_DocBrowser_kind_module)
            put_match!(rb, hit_title(b.cat, h), nothing, action)
            k = manual_page_of(b.cat, h.path)
            where = !isempty(h.heading) ? " " * manual_title(b.cat, h.path) :
                k === nothing ? "" : " " * getfield(SIDEBAR_TITLES, b.cat.manual[k].role)
            isempty(where) || put_right!(rb, w, where)
        elseif r.kind === :header
            title = r.group === :manual_hits ? "In the manual" : r.group === :name_hits ? "Names" :
                r.group === :text_hits ? "In docstrings" : kind_title(r.group)
            put_seg!(rb, r.group in b.collapsed ? " ▸ " : " ▾ ", :REPL_DocBrowser_dim, action)
            put_seg!(rb, title, :REPL_DocBrowser_section, action)
            put_seg!(rb, " $(r.count)", :REPL_DocBrowser_dim, action)
        else
            e = r.entry::NameEntry
            dot = if b.color
                e.vis === :exported ? " ●" : e.vis === :public ? " ○" : " ·"
            else
                e.vis === :exported ? " E" : e.vis === :public ? " P" : " -"
            end
            put_seg!(rb, dot, vis_face(e.vis))
            put_seg!(rb, kind_glyph(e.kind), kind_face(e.kind))
            put_seg!(rb, " ")
            name = is_module_entry(e) ? display_name(e.mod) : String(e.name)
            # A name without a docstring is not dimmed: that would make it look internal.
            face = e.vis === :internal ? :REPL_DocBrowser_dim : nothing
            e.deprecated && (face = [:REPL_DocBrowser_dim, :strikethrough])
            put_match!(rb, name, face, action)
            from = b.query === nothing ? reexported_from(e) : nothing
            if from !== nothing
                # Without room for the package, the arrow alone still says it is a re-export.
                where = " ↗ " * display_name(from)
                room = w - width(rb) - 1
                textwidth(where) > room && (where = " ↗")
                if room >= 2
                    put_seg!(rb, ' '^max(1, room - textwidth(where)))
                    put_seg!(rb, where, :REPL_DocBrowser_dim)
                end
            elseif b.query !== nothing && !is_module_entry(e)
                put_right!(rb, w, " " * display_name(e.mod))
            end
        end
    end
    line = fit(build(rb), w)
    # A long name is cut off at the edge of the pane, and so is the area that can be clicked.
    for k in first_hit:length(b.hits)
        h = b.hits[k]
        b.hits[k] = Hit(h.row, max(first(h.cols), x):min(last(h.cols), x + w - 1), h.action)
    end
    if i == list_state(b, pane).cursor
        if b.focus === pane
            face!(line, :REPL_DocBrowser_selected)
        elseif b.source === pane || pane === :side
            face!(line, :REPL_DocBrowser_unfocused)
        end
        # Without colour the selection would not show, so mark it.
        if !b.color && startswith(String(line), ' ')
            line = concat(b.focus === pane ? "▶" : "›", line[2:end])
        end
    end
    return line
end

# Put `where` at the right of a row `w` columns wide, dimmed, or the start of it that fits.
function put_right!(rb::RowBuilder, w::Int, where::String)
    room = w - width(rb) - 1
    room > 4 || return rb
    put_seg!(rb, ' '^max(1, room - textwidth(where)))
    return put_seg!(rb, textwidth(where) > room ? first(where, room) : where, :REPL_DocBrowser_dim)
end

# The package that a name of another package comes from, for a re-export. Base does not count
# as re-exporting Core, and a module listed under its own name needs no note.
function reexported_from(e::NameEntry)
    from = Base.moduleroot(e.owner)
    to = Base.moduleroot(e.mod)
    (from === to || from === Core && to === Base) && return nothing
    e.kind === :module && nameof(from) === e.name && return nothing
    return from
end

# Show `name`, with the part that matches the search query emphasised.
function put_match!(rb::RowBuilder, name::String, face, action)
    q = rb.b.query
    r = q === nothing || isempty(q) ? nothing : findfirst(lowercase(last(split(q, '.'))), lowercase(name))
    if r === nothing || isempty(r) || ncodeunits(lowercase(name)) != ncodeunits(name)
        put_seg!(rb, name, face, action)
        return
    end
    put_seg!(rb, name[1:prevind(name, first(r))], face, action)
    put_seg!(rb, name[first(r):last(r)], :REPL_DocBrowser_match, action)
    put_seg!(rb, name[nextind(name, last(r)):end], face, action)
end

function draw_list(b::Browser, pane::Symbol, x::Int, w::Int)
    n = content_rows(b)
    lines = AnnotatedString{String}[]
    placeholder = pane === :names ? side_placeholder(b) : nothing
    if placeholder !== nothing
        for k in 1:n
            push!(lines, fit("", w))
        end
        return lines
    end
    ls = list_state(b, pane)
    offset = list_offset(b, pane)
    len = list_length(b, pane) - offset
    m = list_rows(b, pane)
    ls.scroll = clamp(ls.scroll, 0, max(0, len - m))
    for k in 1:m
        push!(lines, list_line(b, pane, offset + ls.scroll + k, x, w, k + 2))
    end
    if m < n
        rb = RowBuilder(b, n + 2, x)
        put_segs!(rb, names_legend(b, w))
        push!(lines, fit(build(rb), w))
    end
    return lines
end

key_title(b::Browser, @nospecialize(key)) =
    key isa NameEntry ? display_name(key) :
    key isa ModuleTarget ? display_name(key.mod) :
    key isa SectionTarget ? getfield(SECTION_TITLES, key.role) :
    key isa LoadTarget ? (isempty(key.then) ? key.id.name : key.then) :
    key isa ManualTarget ? manual_title(b.cat, key.path) :
    key === :start ? "Start" :
    key === :help ? "Keys and mouse" : ""

function pane_title(b::Browser, pane::Symbol, x::Int, w::Int)
    rb = RowBuilder(b, 2, x)
    face = b.focus === pane ? :REPL_DocBrowser_title : :REPL_DocBrowser_section
    if pane === :side
        put_seg!(rb, " Contents", face, (:focus, :side))
    elseif pane === :names
        placeholder = side_placeholder(b)
        if placeholder !== nothing
            put_seg!(rb, " " * getfield(SECTION_TITLES, placeholder.role), face, (:focus, :names))
        elseif names_offset(b) == 1
            return list_line(b, :names, 1, x, w, 2)
        else
            put_seg!(rb, " Results", face, (:focus, :names))
            put_seg!(rb, " $(length(b.results) + length(b.manual_hits))", :REPL_DocBrowser_dim)
        end
    else
        key = current_key(b)
        title = key_title(b, key)
        p = page(b, key, doc_width(b))
        n = content_rows(b)
        pos = length(p.lines) <= n ? "" :
            string(round(Int, 100 * min(b.doc_scroll + n, length(p.lines)) / length(p.lines)), "% ")
        # Say whether this is a page written as a guide, or the docstrings of some code.
        kind = key isa ManualTarget ? "manual" : key isa NameEntry || key isa ModuleTarget ? "docstrings" : ""
        isempty(kind) || (pos = kind * (isempty(pos) ? " " : " · " * pos))
        put_seg!(rb, " " * title, face, (:focus, :doc))
        link = place_link(b) === nothing ? "" : "⧉ link"
        room = w - width(rb)
        if !isempty(link) && room > textwidth(pos) + textwidth(link) + 3
            put_seg!(rb, ' '^(room - textwidth(pos) - textwidth(link) - 2))
            put_seg!(rb, link, :REPL_DocBrowser_link, (:copylink,))
            put_seg!(rb, "  " * pos, :REPL_DocBrowser_dim)
        elseif room > textwidth(pos)
            put_seg!(rb, ' '^(room - textwidth(pos)) * pos, :REPL_DocBrowser_dim)
        end
    end
    return fit(build(rb), w)
end

function draw_doc(b::Browser, x::Int, w::Int)
    n = content_rows(b)
    pw = max(10, w - 1)
    key = current_key(b)
    if !same_key(key, b.doc_key)
        # The help covers a page for a while, which should be as it was when the help closes.
        under = b.under_help
        key === :help && (b.under_help = (b.doc_key, b.doc_scroll, b.link))
        b.doc_key = key
        b.doc_scroll, b.link = under !== nothing && same_key(under[1], key) ? (under[2], under[3]) : (0, 0)
        b.mark = 0
        b.doc_line = 0
        b.pointer_block = 0
        key === :help || (b.under_help = nothing)
        # What was under the pointer, and what was selected, belonged to the old page.
        b.hover = nothing
        b.sel = nothing
        b.dragging = false
    end
    p = page(b, key, pw)
    maxscroll = max(0, length(p.lines) - n)
    b.doc_scroll = clamp(b.doc_scroll, 0, maxscroll)
    # The cursor starts on the selected link, and stays in view when the page scrolls under it.
    b.doc_line == 0 && b.link in eachindex(p.spots) && (b.doc_line = p.spots[b.link].line)
    b.doc_line = clamp(b.doc_line, b.doc_scroll + 1, max(b.doc_scroll + 1, min(b.doc_scroll + n, length(p.lines))))
    # A picture shows the rows of it that are in view, if the pane is wide enough for it.
    for img in p.images
        top, bottom = max(img.line, b.doc_scroll + 1), min(img.line + img.picture.rows - 1, b.doc_scroll + n)
        expected(b, img.picture) !== nothing && top <= bottom && img.col + img.picture.cols - 1 <= pw || continue
        push!(b.placements, Placement(img.picture, top - b.doc_scroll + 2, x + img.col - 1, top - img.line, bottom - top + 1))
    end
    # A scroll bar in the last column, when the page does not fit.
    thumb = 0:-1
    if maxscroll > 0
        size = max(1, round(Int, n * n / length(p.lines)))
        start = round(Int, (n - size) * b.doc_scroll / maxscroll)
        thumb = (start + 1):(start + size)
    end
    lines = AnnotatedString{String}[]
    cursor_block = b.focus === :doc ? code_block_start(p, b.doc_line) : 0
    for k in 1:n
        li = b.doc_scroll + k
        line = li <= length(p.lines) ? copy_line(p.lines[li]) : AnnotatedString("")
        b.searchmode !== :names && b.query !== nothing && mark_words!(line, b.query)
        li == b.mark && startswith(String(line), ' ') &&
            (line = concat(styled("▶", :REPL_DocBrowser_key), line[2:end]))
        for (si, s) in enumerate(p.spots)
            s.line == li && !(s.target isa CodeTarget) || continue
            face_cols!(line, s.cols, si == b.link ? :REPL_DocBrowser_link_active : :REPL_DocBrowser_link)
            b.hover == (:spot, si) && face_cols!(line, s.cols, :REPL_DocBrowser_link_active)
            push!(b.hits, Hit(k + 2, (x + first(s.cols) - 1):(x + last(s.cols) - 1), (:spot, si)))
        end
        # The ⧉ of a block of code shows while the pointer or the cursor is in the block, on its
        # first line, or on the top line of the pane when that is scrolled away.
        start = code_block_start(p, li)
        if start != 0 && (li == start || k == 1) && start in (b.pointer_block, cursor_block)
            si = copy_spot(p, start)
            if si !== nothing && startswith(String(line), ' ')
                active = si == b.link || b.hover == (:spot, si)
                line = concat(styled("⧉", active ? :REPL_DocBrowser_link_active : :REPL_DocBrowser_link), line[2:end])
                push!(b.hits, Hit(k + 2, x:x, (:spot, si)))
            end
        end
        cols = selected_cols(b, li)
        if cols !== nothing
            # The indentation is not copied, so do not show it as selected.
            str = String(line)
            indent = textwidth(str) - textwidth(lstrip(str))
            face_cols!(line, max(first(cols), indent + 1):last(cols), :REPL_DocBrowser_selection)
        end
        line = fit(line, pw)
        # A block of code is shaded to the edge of the pane, leaving its margin out.
        li <= length(p.lines) && is_code_line(p.lines[li]) && face_cols!(line, 3:pw, :REPL_DocBrowser_code_block)
        if li == b.doc_line && b.focus === :doc && li <= length(p.lines)
            face!(line, :REPL_DocBrowser_cursor)
            !b.color && startswith(String(line), ' ') && (line = concat("›", line[2:end]))
        end
        if maxscroll > 0
            bar = styled(k in thumb ? "┃" : "│", k in thumb ? :REPL_DocBrowser_key : :REPL_DocBrowser_border)
            push!(b.hits, Hit(k + 2, (x + pw):(x + pw), (:scrollbar, (k - 1) / max(1, n - 1))))
            line = concat(line, bar)
        else
            line = fit(line, w)
        end
        push!(lines, line)
    end
    return lines
end

# Emphasise the words of a text search where they appear in `line`.
function mark_words!(line::AnnotatedString, query::String)
    str = String(line)
    low = lowercase(str)
    ncodeunits(low) == ncodeunits(str) || return
    for w in split(lowercase(query))
        length(w) >= 2 || continue
        for r in findall(w, low)
            face!(line, first(r):thisind(str, last(r)) + ncodeunits(str[thisind(str, last(r))]) - 1, :REPL_DocBrowser_match)
        end
    end
end

function frame(b::Browser)
    empty!(b.hits)
    empty!(b.placements)
    if !b.gave_up && !isempty(b.awaited) && time() - b.sent > PICTURE_WAIT
        b.gave_up = true
        filter!(kv -> kv.first[1] !== :start, b.pages) # drawn with room for its picture
    end
    H, W = b.height, b.width
    if H < 6 || W < 24
        return [rpad(first(i == 1 ? " Terminal too small" : "", W), W) for i in 1:H]
    end
    rows = Vector{String}(undef, H)
    panes = layout(b)
    # Draw the doc pane first, since drawing it updates the current page.
    order = sortperm([pane === :doc ? 0 : 1 for (pane, _, _) in panes])
    built = Vector{Tuple{AnnotatedString{String},Vector{AnnotatedString{String}}}}(undef, length(panes))
    for i in order
        pane, x, w = panes[i]
        lines = pane === :doc ? draw_doc(b, x, w) : draw_list(b, pane, x, w)
        built[i] = (pane_title(b, pane, x, w), lines)
    end
    sep = styled("│", :REPL_DocBrowser_border)
    styled_rows = Vector{AnnotatedString{String}}(undef, H)
    for r in 1:content_rows(b)+1
        parts = AnnotatedString{String}[]
        for (i, (title, lines)) in enumerate(built)
            i > 1 && push!(parts, sep)
            push!(parts, r == 1 ? title : lines[r-1])
        end
        styled_rows[r+1] = concat(parts...)
    end
    styled_rows[1] = header_bar(b)
    styled_rows[H] = footer_bar(b)
    under = copy(styled_rows)
    overlay_card!(b, styled_rows)
    overlay_console!(b, styled_rows)
    overlay_modal!(b, styled_rows)
    # The terminal draws a picture over the text, so one in a row that a card or a panel
    # covers is left out.
    filter!(p -> all(r -> styled_rows[r] === under[r], p.row:p.row+p.rows-1), b.placements)
    for r in 1:H
        rows[r] = ansi(styled_rows[r], b.color)
    end
    return rows
end

ansi(s::AnnotatedString, color::Bool=true) = sprint(print, s; context = :color => color)

# Writes to the terminal, whose type is not known. The call is left to run time, since a
# package that adds a method of `write` for its own kind of `IO` would otherwise invalidate
# everything that writes, from the handling of keys up.
put(b::Browser, x...) = (Base.inferencebarrier(write)(b.out, x...); nothing)

# The rows that changed, in one write. Each one's line is deleted and put back blank before it
# is written: xterm.js, VS Code's terminal, keeps a hyperlink's marker until its line is
# deleted, so lines written over in place kept every link they ever showed, and leaving the
# screen took longer the more there were. A delete only works inside the scroll region, which
# is set to the whole screen first.
function draw(b::Browser)
    rows = StyledStrings.withfaces(() -> frame(b), b.faces)
    buf = IOBuffer()
    print(buf, "\e[?2026h\e[r")
    written = false
    for (i, r) in enumerate(rows)
        if i > length(b.prev) || b.prev[i] != r
            print(buf, "\e[", i, ";1H\e[M\e[L\e[0m", r, "\e[0m")
            written = true
        end
    end
    # A row is written by deleting its line, and what that does to a picture on it or below
    # it is up to the terminal, so the pictures are all put back after any row is written.
    if b.placements != b.shown || written && !isempty(b.shown)
        for (n, p) in enumerate(b.shown)
            hide_placement(buf, n, p)
        end
        for (n, p) in enumerate(b.placements)
            show_placement(buf, n, p)
        end
        b.shown = copy(b.placements)
    end
    print(buf, "\e[?2026l")
    put(b, take!(buf))
    Base.inferencebarrier(flush)(b.out)
    b.prev = rows
    nothing
end

## Terminal setup ##

const ENTER_SCREEN = "\e[?1049h\e[?25l\e[?7l\e[?1000h\e[?1002h\e[?1003h\e[?1006h\e[?2004h\e[H\e[2J"
const LEAVE_SCREEN = "\e[?2004l\e[?1006l\e[?1003l\e[?1002l\e[?1000l\e[?7h\e[?25h\e[?1049l"

# Only a console has a raw mode, and only while it is open.
function set_raw(term::REPL.Terminals.TextTerminal, raw::Bool)
    term isa REPL.Terminals.TTYTerminal && !(term.in_stream isa Base.TTY && isopen(term.in_stream)) && return
    dynamic(REPL.Terminals.raw!)(term, raw)
    return
end

has_colour(term::REPL.Terminals.TextTerminal) =
    get(term.out_stream, :color, true)::Bool || REPL.Terminals.hascolor(term)

# The browser that `browse` opens on `term`. The terminal is asked about pictures before the
# browser is made, which takes a while, so that it has answered by the time there is a frame
# to draw. Its answers must not be echoed, so it goes into raw mode first.
function opening(term::REPL.Terminals.TextTerminal)
    ask = has_colour(term) && images_enabled()
    if ask
        set_raw(term, true)
        Base.inferencebarrier(write)(term.out_stream, GRAPHICS_QUERY)
        Base.inferencebarrier(flush)(term.out_stream)
    end
    try
        b = Browser(term)
        b.answered = !ask
        return b
    catch
        ask && set_raw(term, false)
        rethrow()
    end
end

# Asks whether the terminal is dark or light, now and when that changes, and for its
# background colour, for the rich faces.
scheme_reports(on::Bool) = on ? "\e[?2031h\e[?996n\e]11;?\e\\" : "\e[?2031l"

function enter_screen(b::Browser)
    set_raw(b.term, true)
    put(b, ENTER_SCREEN)
    rich_colours() && put(b, scheme_reports(true))
    # Entering the screen throws away the pictures in some terminals, such as Ghostty, so
    # those the terminal had are sent again.
    isempty(b.pictures) || send_logos!(b, splice!(b.pictures, eachindex(b.pictures)))
    flush(b.out)
    b.prev = String[]
    empty!(b.shown)
end

# `closing` is whether the browser is leaving for good, and not for a while, as for an editor.
function leave_screen(b::Browser, closing::Bool=false)
    buf = IOBuffer()
    closing && foreach(pic -> forget_picture(buf, pic), vcat(b.pictures, b.awaited))
    put(b, String(take!(buf)) * (rich_colours() ? scheme_reports(false) : "") * LEAVE_SCREEN)
    flush(b.out)
    # Mouse reports sent before reporting stopped would reach the prompt, and so would the
    # terminal's answer about a picture still on its way. They must be read while still in raw
    # mode, which delivers them without waiting for a newline.
    closing && drain_reports(b.in, isempty(b.awaited) || b.gave_up ? 0.05 : 1.0)
    set_raw(b.term, false)
end

function check_size!(b::Browser)
    h, w = displaysize(b.term)
    (h, w) == (b.height, b.width) && return false
    b.height, b.width = h, w
    clear_screen!(b)
    return true
end

# Makes the next frame draw every row. Each row is blanked before it is written, so the
# screen is not erased, which in Ghostty also throws away the pictures that are not in view.
function clear_screen!(b::Browser)
    b.prev = String[]
    return
end

## The preview card ##

# How long the pointer rests on something before its card shows, in seconds.
const CARD_DELAY = 0.175

card_width(b::Browser) = clamp(b.width ÷ 2, 30, 64)

# What the pointer rests on, as something a card can preview, or `nothing`.
function card_subject(b::Browser, @nospecialize(action))
    action isa Tuple || return nothing
    kind = first(action)::Symbol
    if kind === :spot
        p = current_page(b)
        k = action[2]::Int
        k in eachindex(p.spots) || return nothing
        t = p.spots[k].target
        return t isa NameTarget || t isa ModuleTarget || t isa ManualTarget ? t : nothing
    elseif kind === :names
        row = get(b.name_rows, action[2]::Int, nothing)
        row === nothing && return nothing
        row.kind === :entry && return row.entry
        row.kind in (:hit, :pkgpage) && return ManualTarget(row.hit.path, row.hit.heading)
    elseif kind === :side
        row = get(b.side_rows, action[2]::Int, nothing)
        row === nothing && return nothing
        row.pkg === nothing || return ModuleTarget(row.pkg.mod)
        row.page === nothing || return ManualTarget(row.page.path, "")
    end
    return nothing
end

"""
    card_lines(b, subject, width) -> Vector{AnnotatedString}

What the card of `subject` says: its name, and the start of its documentation: a docstring's
signature and first paragraph, or the first paragraph of a section of the manual.
"""
function card_lines(b::Browser, @nospecialize(subject), width::Int)
    title, kind, md = card_content(b, subject)
    lines = AnnotatedString{String}[concat(styled(title, :REPL_DocBrowser_title),
                                                    styled(isempty(kind) ? "" : "  " * kind, :REPL_DocBrowser_dim))]
    body = md === nothing ? AnnotatedString{String}[] : render_markdown(md, width)
    while !isempty(body) && isempty(strip(String(first(body))))
        popfirst!(body)
    end
    while !isempty(body) && isempty(strip(String(last(body))))
        pop!(body)
    end
    if isempty(body)
        push!(lines, styled("No documentation", :REPL_DocBrowser_dim))
    else
        push!(lines, AnnotatedString(""))
        append!(lines, body[1:min(end, 8)])
        length(body) > 8 && push!(lines, styled("…", :REPL_DocBrowser_dim))
    end
    push!(lines, AnnotatedString(""))
    push!(lines, styled("click to open · right-click: source", :REPL_DocBrowser_dim))
    return lines
end

function card_content(b::Browser, @nospecialize(subject))
    if subject isa NameEntry || subject isa NameTarget
        m, s = subject.mod::Module, subject.name::Symbol
        e = subject isa NameEntry ? subject : @attempt(classify(b.cat, m, s))
        kind = e === nothing ? "" : String(e.kind)
        return string(display_name(m), '.', s), kind, docstring_start(doc_results(Binding(m, s)))
    elseif subject isa ModuleTarget
        return display_name(subject.mod), "module", docstring_start(doc_results(module_binding(subject.mod)))
    elseif subject isa ManualTarget
        k = anchor_heading(b.cat, subject.path, subject.anchor)
        hs = page_headings(b.cat, subject.path)
        title = k in eachindex(hs) ? hs[k].text : manual_title(b.cat, subject.path)
        return title, "manual · " * manual_title(b.cat, subject.path), section_start(subject.path, k)
    end
    return "", "", nothing
end

# A docstring's signature and first paragraph.
function docstring_start(results)
    isempty(results) && return nothing
    blocks = Any[]
    for x in md_blocks(dynamic(REPL.parsedoc)(first(results)))
        if x isa Markdown.Code && isempty(blocks)
            push!(blocks, x)
        elseif x isa Markdown.Paragraph
            push!(blocks, x)
            break
        end
    end
    return isempty(blocks) ? nothing : Markdown.MD(blocks)
end

md_blocks(md::Markdown.MD) = mapreduce(x -> x isa Markdown.MD ? md_blocks(x) : Any[x], vcat, md.content; init=Any[])

# The first paragraph of the section of a manual page under its `k`th shown heading.
function section_start(path::String, k::Int)
    md = @attempt Markdown.parse(read(path, String)) return nothing
    seen = 0
    for x in md_blocks(md)
        if x isa Markdown.Header
            seen += 1
        elseif x isa Markdown.Paragraph && seen >= max(k, 1)
            return Markdown.MD(Any[x])
        end
    end
    return nothing
end

# Show the card of what the pointer has rested on. Returns whether the screen must change.
function show_card!(b::Browser, now::Float64=time())
    b.card === nothing && b.hover !== nothing && now - b.hover_since >= CARD_DELAY || return false
    b.hover_since = Inf # once, until the pointer moves on
    subject = card_subject(b, b.hover)
    subject === nothing && return false
    b.card = (card_lines(b, subject, card_width(b) - 4), subject)
    return true
end

# The pointer came to rest on something. Its card shows after a moment, if the pointer is
# still there then.
function rest_pointer!(b::Browser)
    b.hover_since = time()
    stop_card_timer!(b)
    b.live && (b.card_timer = Timer(_ -> tick(b), CARD_DELAY + 0.01))
    return
end

function stop_card_timer!(b::Browser)
    b.card_timer === nothing || close(b.card_timer)
    b.card_timer = nothing
end

function hide_card!(b::Browser)
    b.hover_since = Inf
    b.card === nothing && return false
    b.card = nothing
    return true
end

# Draw the card over the rows of the screen, below the pointer, or above it when there is no room.
function overlay_card!(b::Browser, rows::Vector{AnnotatedString{String}})
    b.card === nothing && return
    lines = b.card[1]
    cw = card_width(b)
    h = length(lines) + 2
    r0, c0 = b.hover_at
    top = r0 + h <= b.height - 1 ? r0 + 1 : max(2, r0 - h)
    # a little to the right of the pointer, so that it does not cover what it describes
    left = clamp(c0 + 2, 1, max(1, b.width - cw + 1))
    border = :REPL_DocBrowser_border
    box = AnnotatedString{String}[styled("╭" * "─"^(cw - 2) * "╮", border)]
    for l in lines
        push!(box, concat(styled("│ ", border), fit(l, cw - 4), styled(" │", border)))
    end
    push!(box, styled("╰" * "─"^(cw - 2) * "╯", border))
    for (i, piece) in enumerate(box)
        r = top + i - 1
        2 <= r <= b.height - 1 || continue
        rows[r] = splice_cols(rows[r], left, piece)
        push!(b.hits, Hit(r, left:left+cw-1, (:card,)))
    end
end

# Draw the console panel over the rows just above the footer: the import, and the last lines
# that loading printed.
function overlay_console!(b::Browser, rows::Vector{AnnotatedString{String}})
    b.console === nothing && return
    lines = b.console
    n = min(length(lines), max(1, (b.height - 3) ÷ 3))
    shown = n == length(lines) ? lines : [lines[1]; lines[end-n+2:end]]
    border = :REPL_DocBrowser_border
    w = b.width
    title = isempty(b.loading) ? " Loading failed " : " $(b.loading) "
    box = AnnotatedString{String}[concat(styled("╭─", border), styled(title, :REPL_DocBrowser_section),
                                                  styled("─"^max(0, w - 4 - textwidth(title)) * "╮", border))]
    for (i, l) in enumerate(shown)
        text = i == 1 ? concat(styled("julia> ", :repl_prompt_julia), l[8:end]) : AnnotatedString(l)
        push!(box, concat(styled("│ ", border), fit(text, w - 4), styled(" │", border)))
    end
    push!(box, styled("╰" * "─"^(w - 2) * "╯", border))
    top = max(2, b.height - length(box))
    for (i, piece) in enumerate(box)
        r = top + i - 1
        r <= b.height - 1 || continue
        rows[r] = piece
        push!(b.hits, Hit(r, 1:w, (:console,)))
    end
end

# The notice that a package is being loaded, over the middle of the screen.
function overlay_modal!(b::Browser, rows::Vector{AnnotatedString{String}})
    isempty(b.modal) && return
    text = "   " * b.modal * "   "
    w = textwidth(text) + 2
    left = max(1, (b.width - w) ÷ 2 + 1)
    top = max(2, b.height ÷ 2 - 1)
    border = :REPL_DocBrowser_border
    box = [styled("╭" * "─"^(w - 2) * "╮", border),
           concat(styled("│", border), styled(text, :REPL_DocBrowser_title), styled("│", border)),
           styled("╰" * "─"^(w - 2) * "╯", border)]
    for (i, piece) in enumerate(box)
        r = top + i - 1
        r <= b.height - 1 && (rows[r] = splice_cols(rows[r], left, piece))
    end
end

# `line` with `piece` drawn over it from column `col`.
splice_cols(line::AnnotatedString{String}, col::Int, piece::AnnotatedString{String}) =
    concat(take_cols(line, 1, col - 1), piece, take_cols(line, col + textwidth(String(piece)), typemax(Int)))

# The columns `from` to `to` of `s`, with spaces for the part of a wide character cut at an edge.
function take_cols(s::AnnotatedString{String}, from::Int, to::Int)
    str = String(s)
    first_i = last_i = 0
    lead = trail = 0
    col = 1
    for (i, c) in pairs(str)
        stop = col + textwidth(c) - 1
        if col >= from && stop <= to
            first_i == 0 && (first_i = i)
            last_i = i
        elseif col < from <= stop
            lead = stop - from + 1
        elseif col <= to < stop
            trail = to - col + 1
        end
        col = stop + 1
        col > to && break
    end
    mid = first_i == 0 ? AnnotatedString("") : s[first_i:last_i]
    return concat(' '^lead, mid, ' '^trail)
end

## Selecting text ##

# The page line and column under a point of the documentation pane. With `clamped`, a point
# outside the pane counts as the nearest point inside it, so a drag can leave the pane.
function doc_point(b::Browser, row::Int, col::Int, clamped::Bool=false)
    n = content_rows(b)
    for (pane, x, w) in layout(b)
        pane === :doc || continue
        pw = max(10, w - 1) # the last column holds the scroll bar
        if clamped
            row = clamp(row, 3, n + 2)
            col = clamp(col, x, x + pw - 1)
        end
        (3 <= row <= n + 2 && x <= col < x + pw) || return nothing
        return (b.doc_scroll + row - 2, col - x + 1)
    end
    return nothing
end

# The columns of page line `li` that are selected.
function selected_cols(b::Browser, li::Int)
    b.sel === nothing && return nothing
    l1, c1, l2, c2 = ordered_selection(b.sel)
    l1 <= li <= l2 || return nothing
    return (li == l1 ? c1 : 1):(li == l2 ? c2 : typemax(Int) ÷ 2)
end

function ordered_selection(s::NTuple{4,Int})
    l1, c1, l2, c2 = s
    return (l2, c2) < (l1, c1) ? (l2, c2, l1, c1) : (l1, c1, l2, c2)
end

# The characters of `s` that start in columns `from` to `to`.
function col_slice(s::String, from::Int, to::Int)
    io = IOBuffer()
    col = 1
    for c in s
        from <= col <= to && print(io, c)
        col += textwidth(c)
    end
    return String(take!(io))
end

# Characters that make up a word for a double-click, so a path, a URL or `Base.sort!` is one word.
is_word_char(c::Char) = isletter(c) || isdigit(c) || c in "_!@.-/~+:\\#%=?&"

# The columns of the word at column `col` of `s`, without punctuation that ends a sentence.
function word_cols(s::String, col::Int)
    starts = Int[]
    chars = Char[]
    at = 1
    for c in s
        push!(starts, at)
        push!(chars, c)
        at += textwidth(c)
    end
    i = findlast(<=(col), starts)
    # past the end of the line, there is no word
    (i === nothing || col >= starts[i] + max(1, textwidth(chars[i]))) && return nothing
    is_word_char(chars[i]) || return nothing
    a = z = i
    while a > 1 && is_word_char(chars[a-1])
        a -= 1
    end
    while z < length(chars) && is_word_char(chars[z+1])
        z += 1
    end
    while z > a && chars[z] in ".:,?"
        z -= 1
    end
    return starts[a]:(starts[z] + textwidth(chars[z]) - 1)
end

"""
    selection_text(b) -> String

The selected text, without the indentation that the page adds to every line.
"""
function selection_text(b::Browser)
    b.sel === nothing && return ""
    l1, c1, l2, c2 = ordered_selection(b.sel)
    p = current_page(b)
    lines = String[]
    for li in l1:min(l2, length(p.lines))
        cols = selected_cols(b, li)::UnitRange{Int}
        text, shift = copy_view(p, li)
        push!(lines, rstrip(col_slice(text, max(1, first(cols) - shift), last(cols) - shift)))
    end
    # A selection that starts mid-line keeps its first line as it is. One that starts in the
    # indentation starts at the line's text.
    first_line, shift = l1 <= length(p.lines) ? copy_view(p, l1) : ("", 0)
    c1 -= shift
    first_indent = textwidth(first_line) - textwidth(lstrip(first_line))
    if !isempty(lines) && 1 < c1 <= first_indent + 1
        lines[1] = rstrip(col_slice(first_line, 1, last(selected_cols(b, l1)::UnitRange{Int}) - shift))
    end
    whole = c1 > first_indent + 1 ? (2:length(lines)) : eachindex(lines)
    indent = typemax(Int)
    for i in whole
        isempty(lines[i]) || (indent = min(indent, length(lines[i]) - length(lstrip(lines[i]))))
    end
    if indent != typemax(Int)
        for i in whole
            lines[i] = chop(lines[i]; head=min(indent, length(lines[i])), tail=0)
        end
    end
    return String(strip(join(lines, '\n'), '\n'))
end

# A line of the page as it is copied, and how many columns it lost: code loses the margin
# it is indented by on the screen, where its ⧉ goes.
function copy_view(p::Page, li::Int)
    text = String(p.lines[li])
    is_code_line(p.lines[li]) || return (text, 0)
    return (String(chop(text; head=2, tail=0)), 2)
end

# The key that makes the terminal select text itself, rather than pass the mouse on.
function native_select_key()
    term = get(ENV, "TERM_PROGRAM", "")
    return term == "iTerm.app" ? "Option" : term == "Apple_Terminal" ? "Fn" : "Shift"
end

"""
    copy_to_clipboard(b, text) -> String

Copy `text` to the clipboard, and say how. Over SSH the local clipboard is not the user's, so
the text goes to the terminal instead, as an OSC 52 sequence.
"""
function copy_to_clipboard(b::Browser, text::String)
    if !haskey(ENV, "SSH_CONNECTION")
        # With no clipboard program, as on a server, the terminal is asked instead.
        @attempt (InteractiveUtils.clipboard(text); return "to the clipboard")
    end
    put(b, "\e]52;c;", base64encode(text), "\a")
    return "through the terminal"
end

# How selections are copied. Tests replace it, so they do not touch the clipboard.
const COPY = Ref{Any}(copy_to_clipboard)

function copy_selection!(b::Browser)
    text = selection_text(b)
    isempty(text) && return true
    how = COPY[](b, text)
    n = count(==('\n'), text) + 1
    what = n == 1 ? "$(length(text)) characters" : "$n lines"
    b.status = "Copied $what $how · $(native_select_key())-drag selects with the terminal"
    return true
end

# What to write after `docs: ` to come back to the page shown, at the section scrolled to.
function place_link(b::Browser)
    key = current_key(b)
    k = 0
    if key isa ManualTarget && b.doc_scroll > 0
        p = page(b, key, doc_width(b))
        k = something(findlast(<=(b.doc_scroll + 1), p.headings), 0)
    end
    return place_ref(b.cat, key, k)
end

function copy_place!(b::Browser)
    ref = place_link(b)
    ref === nothing && return (b.status = "This page has no link"; true)
    text = "help?> docs: " * ref
    how = COPY[](b, text)
    b.status = "Copied $text $how · paste it at the julia> prompt to come back here"
    return true
end

# A press in the text of the documentation. One click starts a selection, two select a word
# and three a line.
function press_doc!(b::Browser, row::Int, col::Int)
    pt = doc_point(b, row, col)
    pt === nothing && return false
    t, r, c, n = b.clicks
    now = time()
    n = now - t < 0.4 && (r, c) == (row, col) ? n + 1 : 1.0
    b.clicks = (now, row, col, n)
    b.focus = :doc
    li, col = pt
    p = current_page(b)
    b.doc_line = li
    b.link in eachindex(p.spots) && p.spots[b.link].line == li || (b.link = line_link(p, li))
    text = li <= length(p.lines) ? String(p.lines[li]) : ""
    if n == 1
        b.sel = (li, col, li, col)
        b.dragging = true
        return true
    end
    cols = n == 2 ? word_cols(text, col) : 1:max(1, textwidth(text))
    cols === nothing && return true
    b.sel = (li, first(cols), li, last(cols))
    return copy_selection!(b)
end

function drag_selection!(b::Browser, row::Int, col::Int)
    # Dragging past the top or bottom of the pane scrolls it.
    row < 3 && scroll_doc!(b, -1)
    row > content_rows(b) + 2 && scroll_doc!(b, 1)
    pt = doc_point(b, row, col, true)
    (pt === nothing || b.sel === nothing) && return false
    b.sel = (b.sel[1], b.sel[2], pt[1], pt[2])
    return true
end

function release_selection!(b::Browser)
    b.dragging = false
    s = b.sel
    s === nothing && return false
    if (s[1], s[2]) == (s[3], s[4])
        b.sel = nothing # a click, not a selection
        return true
    end
    return copy_selection!(b)
end

## Events ##

function move!(b::Browser, pane::Symbol, delta::Int)
    ls = list_state(b, pane)
    len = list_length(b, pane)
    len == 0 && return
    ls.cursor = clamp(ls.cursor + delta, 1, len)
    reveal!(ls, list_rows(b, pane), list_offset(b, pane))
    b.override = nothing
    b.source = pane
    pane === :side && sync_side!(b)
    pane === :names && show_heading!(b)
end

"""
    open_manual!(b, t::ManualTarget)

Show a page of the manual, at the heading that `t` names. A page in the sidebar is picked
there, so that the names pane lists its headings; any other page, such as the manual page of
a package, is shown on its own.
"""
open_manual!(b::Browser, t::ManualTarget) = open_manual!(b, t.path, anchor_heading(b.cat, t.path, t.anchor))

function open_manual!(b::Browser, path::String, k::Int)
    i = manual_page_of(b.cat, path)
    navigate!(b) do
        b.query === nothing || close_search!(b)
        b.override = nothing
        b.focus = :doc
        i === nothing && (b.override = ManualTarget(path, ""))
        i === nothing && return
        p = b.cat.manual[i]
        # The page of a loaded standard library is one of the pages its row lists.
        lib = stdlib_package(b, p)
        pkg = p.role === :pkgdocs && lib === nothing
        unfold_to!(b, p.role === :pkgdocs ? :stdlibdocs : p.role; open=true)
        j = findfirst(r -> lib !== nothing ? r.pkg === lib && r.role === :stdlibdocs :
                           pkg ? r.role === :pkgdocs : r.page == p, b.side_rows)
        j === nothing || (b.side.cursor = j)
        reveal!(b.side, content_rows(b))
        b.source = :side
        sync_side!(b)
        if lib !== nothing
            n = findfirst(r -> r.kind === :pkgpage && r.hit.path == path, b.name_rows)
            n === nothing || (b.names.cursor = n; b.source = :names)
        elseif pkg
            # Unfold the page in the names pane and pick it, so that it is the page shown.
            push!(b.expanded, Symbol(path))
            refresh_names!(b)
            n = findfirst(r -> r.kind === :page && r.hit.path == path, b.name_rows)
            n === nothing || (b.names.cursor = n)
        end
    end
    scroll_to_heading!(b, k)
    i === nothing && return # the names pane lists something else
    # Pick the heading in the names pane too.
    r = findfirst(r -> r.kind === :heading && r.count == k && (r.hit === nothing || r.hit.path == path), b.name_rows)
    r === nothing || (b.names.cursor = r; reveal!(b.names, list_rows(b, :names), names_offset(b)))
end

# When a heading of a manual page is picked, scroll the page to it.
function show_heading!(b::Browser)
    row = name_row(b)
    row !== nothing && row.kind === :hit && return scroll_to_heading!(b, hit_heading(b.cat, row.hit))
    (row === nothing || (side_page(b) === nothing && !on_start(b)) || b.query !== nothing) && return
    row.kind === :heading ? scroll_to_heading!(b, row.count) : scroll_to_heading!(b, 0)
end

function scroll_to_heading!(b::Browser, k::Int)
    key = current_key(b)
    p = page(b, key, doc_width(b))
    b.doc_key = key # so that drawing does not scroll back to the top
    b.doc_scroll = k in eachindex(p.headings) ? p.headings[k] - 1 : 0
    # Near the end of a page it cannot scroll that far, so the heading is marked instead.
    b.mark = k in eachindex(p.headings) ? p.headings[k] : 0
    b.doc_line = b.mark
    b.link = 0
end

function scroll_doc!(b::Browser, delta::Int)
    b.doc_scroll = max(0, b.doc_scroll + delta)
    b.mark = 0
end

# Move the cursor `delta` lines. The page scrolls with it, so the cursor keeps its place on the
# screen, but never closer than a few lines to the top or bottom, so what is around it shows.
# Where the page cannot scroll further, the cursor moves on the screen instead.
function step_doc!(b::Browser, delta::Int)
    p = current_page(b)
    n = content_rows(b)
    from = max(b.doc_line, b.doc_scroll + 1)
    line = clamp(from + delta, 1, max(1, length(p.lines)))
    maxscroll = max(0, length(p.lines) - n)
    margin = min(5, (n - 1) ÷ 2)
    b.doc_scroll = clamp(clamp(b.doc_scroll + line - from, line - n + margin, line - 1 - margin), 0, maxscroll)
    b.doc_line = line
    b.mark = 0
    # The link that ⏎ follows is one on the cursor's line.
    if !(b.link in eachindex(p.spots) && p.spots[b.link].line == line)
        b.link = line_link(p, line)
    end
end

function cycle_link!(b::Browser, dir::Int)
    p = current_page(b)
    # Blocks of code are not stops: the cursor on one is enough to copy it.
    links = [i for (i, s) in enumerate(p.spots) if !(s.target isa CodeTarget)]
    isempty(links) && return (b.status = "No links on this page"; nothing)
    n = content_rows(b)
    k = findfirst(==(b.link), links)
    if k === nothing
        # The first link from the cursor on, or back from it.
        at = max(b.doc_line, b.doc_scroll + 1)
        k = dir > 0 ? findfirst(i -> p.spots[i].line >= at, links) : findlast(i -> p.spots[i].line <= at, links)
        b.link = links[something(k, dir > 0 ? 1 : length(links))]
    else
        b.link = links[mod1(k + dir, length(links))]
    end
    line = p.spots[b.link].line
    if !(b.doc_scroll < line <= b.doc_scroll + n)
        b.doc_scroll = max(0, line - n ÷ 3)
    end
    b.doc_line = line
    # Preview the selected link, as if the pointer rested on it: the card goes below its line.
    for (pane, x, _) in layout(b)
        pane === :doc || continue
        b.hover = (:spot, b.link)
        b.hover_at = (line - b.doc_scroll + 2, x + first(p.spots[b.link].cols) - 1)
        rest_pointer!(b)
    end
end

function toggle_section!(b::Browser, role::Symbol)
    role in b.expanded ? delete!(b.expanded, role) : push!(b.expanded, role)
    refresh_side!(b)
end

function toggle_page!(b::Browser, path::String)
    key = Symbol(path)
    key in b.expanded ? delete!(b.expanded, key) : push!(b.expanded, key)
    refresh_names!(b)
end

function toggle_group!(b::Browser, group::Symbol)
    group in b.collapsed ? delete!(b.collapsed, group) : push!(b.collapsed, group)
    refresh_names!(b)
end

function activate!(b::Browser, pane::Symbol)
    if pane === :side
        row = side_row(b)
        row === nothing && return
        if is_header(row)
            toggle_section!(b, row.role)
        elseif row.unloaded !== nothing
            load_package!(b, row.unloaded)
        else
            b.focus = :names
            b.source = :names
        end
    elseif pane === :names
        row = name_row(b)
        row === nothing && return
        if row.kind === :header
            toggle_group!(b, row.group)
        elseif row.kind === :page
            toggle_page!(b, row.hit.path)
        elseif row.kind === :about && side_unloaded(b) !== nothing
            load_package!(b, side_unloaded(b))
        elseif row.kind === :about || row.kind === :heading || row.kind === :pkgpage
            b.focus = :doc
        elseif row.kind === :hit
            open_manual!(b, row.hit.path, hit_heading(b.cat, row.hit))
        elseif row.kind === :unloaded
            follow!(b, row.target)
        elseif row.kind === :more
            toggle_indirect!(b)
        else
            e = row.entry::NameEntry
            if b.query !== nothing
                open_entry!(b, e)
            elseif e.kind === :module
                open_entry!(b, e)
            else
                b.focus = :doc
            end
        end
    else
        key = current_key(b)
        p = page(b, key, doc_width(b))
        if b.link in eachindex(p.spots)
            follow!(b, p.spots[b.link].target)
        elseif key isa LoadTarget
            load_package!(b, key.id)
        else
            b.status = "No link on this line · ⇥ picks one"
        end
    end
end

function focus_left!(b::Browser)
    if b.focus === :doc
        b.focus = b.source === :side ? :side : :names
    elseif b.focus === :names
        if b.query === nothing && side_page(b) === nothing && !on_start(b) && package_of(b.cat, b.mod) !== nothing &&
                get(b.cat.bymod, b.mod, nothing) === nothing
            # In a submodule, step out to its parent.
            child = b.mod
            navigate!(b) do
                show_module!(b, parentmodule(child); entry=nameof(child))
            end
        else
            b.focus = :side
            b.source = :side
        end
    end
end

function focus_right!(b::Browser)
    if b.focus === :side
        row = side_row(b)
        row === nothing ? nothing : is_header(row) ? toggle_section!(b, row.role) :
            (b.focus = :names; b.source = :names)
    elseif b.focus === :names
        row = name_row(b)
        if row !== nothing && row.kind === :entry && row.entry.kind === :module
            open_entry!(b, row.entry)
        else
            b.focus = :doc
        end
    end
end

function toggle_flag!(b::Browser, flag::Symbol)
    key = current_key(b)
    key isa NameEntry || return
    flags = page_flags!(b, key)
    flag in flags ? delete!(flags, flag) : push!(flags, flag)
end

function next_tip!(b::Browser, dir::Int)
    b.tip = mod1(b.tip + dir, length(b.tips))
    filter!(kv -> kv.first[1] !== :start, b.pages) # drawn with the old tip
end

const MODE_DESCRIPTION = Dict(:all => "names, the manual and the text of docstrings",
                              :names => "names and the titles of the manual",
                              :text => "the text of docstrings and the manual")
const NEXT_MODE_LABEL = Dict(:all => "names", :names => "text", :text => "all")

next_mode(m::Symbol) = m === :all ? :names : m === :names ? :text : :all

function toggle_textsearch!(b::Browser)
    b.searchmode = next_mode(b.searchmode)
    b.query === nothing || update_search!(b)
    b.status = "Searching " * MODE_DESCRIPTION[b.searchmode]
end

function jump_heading!(b::Browser, dir::Int)
    p = current_page(b)
    # From the marked heading, which can be below the top near the end of a page.
    at = b.mark > 0 ? b.mark : b.doc_scroll + 1
    hs = dir > 0 ? filter(>(at), p.headings) : filter(<(at), p.headings)
    isempty(hs) && return (b.status = "No more headings"; nothing)
    b.mark = dir > 0 ? first(hs) : last(hs)
    b.doc_line = b.mark
    b.doc_scroll = b.mark - 1
    b.focus = :doc
end

# Bytes that are not UTF-8, such as from a terminal that sends Alt as the high bit, are dropped.
valid_text(s::AbstractString) = isvalid(s) ? String(s) : filter(isvalid, String(s))

function start_search!(b::Browser, query::String="")
    b.query = valid_text(query)
    b.qcol = length(b.query)
    b.typing = true
    b.focus = :names
    b.source = :names
    b.override = nothing
    update_search!(b)
end

function run_search!(b::Browser)
    q = b.query
    m = b.searchmode
    names = q === nothing || m === :text ? NameEntry[] : search(b.cat, q; internal=b.internal)
    text = q === nothing || m === :names ? NameEntry[] : search_text(b.cat, q; internal=b.internal)
    keep(found) = b.indirect ? found : filter(e -> !is_indirect(b.cat, e), found)
    if m === :all
        # the names that only the text of their docstrings matches, after the names
        named = Set((e.mod, e.name) for e in names)
        text = filter(e -> !((e.mod, e.name) in named), text)
        b.results, b.text_results = keep(names), keep(text)
    else
        b.results, b.text_results = keep(m === :text ? text : names), NameEntry[]
    end
    b.hidden = length(names) + length(text) - length(b.results) - length(b.text_results)
    b.unloaded_hits = q === nothing || m === :text ? Tuple{String,PkgId}[] : search_unloaded(b.cat, q)
    titles = q === nothing || m === :text ? ManualHit[] : search_manual(b.cat, q)
    b.manual_titles = length(titles)
    b.manual_hits = m === :names || q === nothing ? titles :
        m === :text ? search_manual(b.cat, q; text=true) : with_text_hits(b.cat, q, titles)
end

# The manual's titles and headings that match, then the sections whose text does.
function with_text_hits(cat::Catalog, q::AbstractString, titles::Vector{ManualHit}; limit::Int=30)
    hits = copy(titles)
    seen = Set((h.path, h.heading) for h in hits)
    for h in search_manual(cat, q; text=true)
        (h.path, h.heading) in seen || push!(hits, h)
    end
    return first(hits, limit)
end

function is_indirect(cat::Catalog, e::NameEntry)
    p = package_of(cat, e.mod)
    # The standard libraries are left in, since many are loaded by Julia itself.
    return p !== nothing && p.role === :indirect && !is_stdlib(p.id)
end

# Whether searches include indirect dependencies, kept for the next time the browser opens.
const SEARCH_INDIRECT = Ref(false)

function toggle_indirect!(b::Browser)
    b.indirect = SEARCH_INDIRECT[] = !b.indirect
    b.query === nothing || update_search!(b)
    b.status = b.indirect ? "Searching indirect dependencies too" : "Leaving indirect dependencies out of searches"
end

function update_search!(b::Browser)
    run_search!(b)
    b.names = ListState(1, 0)
    refresh_names!(b)
    # Start on the best result, not on the heading of its group.
    first_result = findfirst(r -> r.kind !== :header, b.name_rows)
    first_result === nothing || (b.names.cursor = first_result)
    show_heading!(b)
end

# The browser's own keys come first, and the rest edit the query.
function handle_typing!(b::Browser, ev::KeyEvent)
    if isctrl(ev, 't')
        toggle_textsearch!(b)
    elseif isctrl(ev, 'a')
        toggle_indirect!(b)
    elseif ev.key === :up || isctrl(ev, 'p')
        move!(b, :names, -1)
    elseif ev.key === :down || isctrl(ev, 'n')
        move!(b, :names, 1)
    elseif ev.key in (:pageup, :pagedown)
        move!(b, :names, (ev.key === :pageup ? -1 : 1) * content_rows(b))
    elseif ev.key === :enter
        row = name_row(b)
        if row !== nothing && row.kind === :hit
            b.typing = false
            open_manual!(b, row.hit.path, hit_heading(b.cat, row.hit))
        elseif row !== nothing && row.kind === :more
            toggle_indirect!(b)
        elseif row !== nothing && row.kind === :unloaded
            b.typing = false
            follow!(b, row.target)
        elseif row === nothing || row.entry === nothing
            b.status = "No matches"
        else
            b.typing = false
            open_entry!(b, row.entry::NameEntry)
        end
    elseif ev.key === :tab || ev.key === :right && ev.mods == 0 && b.qcol >= length(b.query)
        # past the end of the query, on to the results
        b.typing = false
    elseif ev.key === :escape || isctrl(ev, 'c') || isctrl(ev, 'g')
        close_search!(b)
    else
        edit_query!(b, ev)
    end
    return true
end

isplain(ev::KeyEvent, c::Char) = ev.key === :char && ev.char == c && ev.mods & (CTRL | ALT) == 0
isctrl(ev::KeyEvent, c::Char) = ev.key === :char && ev.char == c && ev.mods == CTRL
isalt(ev::KeyEvent, c::Char) = ev.key === :char && ev.char == c && ev.mods == ALT

function handle!(b::Browser, ev::KeyEvent)
    # The panel left by a failed load goes with the next key.
    b.console === nothing || !isempty(b.loading) || (b.console = nothing; return true)
    hide_card!(b)
    if b.sel !== nothing && !(ev.key in (:up, :down, :pageup, :pagedown))
        b.sel = nothing
        b.dragging = false
        ev.key === :escape && (b.status = ""; return true)
    end
    b.status = ""
    b.hover = nothing
    FIRST_OPEN[] = false
    if b.help
        if ev.key in (:up, :down, :pageup, :pagedown) || isplain(ev, ' ')
            ev.key === :up ? scroll_doc!(b, -1) : ev.key === :down ? scroll_doc!(b, 1) :
                scroll_doc!(b, (ev.key === :pageup ? -1 : 1) * content_rows(b))
        else
            b.help = false
        end
        return true
    end
    b.typing && return handle_typing!(b, ev)
    pane = b.focus
    n = content_rows(b)
    if isplain(ev, 'q') || isctrl(ev, 'c') || isctrl(ev, 'd')
        b.quit = true
    elseif ev.key === :escape
        if b.query !== nothing
            close_search!(b)
        elseif b.link != 0
            b.link = 0
        else
            b.quit = true
        end
    elseif isplain(ev, '?') || ev.key === :f1
        b.help = true
    elseif isplain(ev, '/') || isctrl(ev, 'f')
        start_search!(b, something(b.query, ""))
    elseif ev.key === :up || isplain(ev, 'k') || isctrl(ev, 'p')
        pane === :doc ? step_doc!(b, -1) : move!(b, pane, -1)
    elseif ev.key === :down || isplain(ev, 'j') || isctrl(ev, 'n')
        pane === :doc ? step_doc!(b, 1) : move!(b, pane, 1)
    elseif ev.key === :pageup || isctrl(ev, 'b') || isalt(ev, 'v')
        pane === :doc ? step_doc!(b, -(n - 2)) : move!(b, pane, -n)
    elseif ev.key === :pagedown || isplain(ev, ' ') || isctrl(ev, 'v')
        pane === :doc ? step_doc!(b, n - 2) : move!(b, pane, n)
    elseif ev.key === :home || isplain(ev, 'g')
        pane === :doc ? step_doc!(b, -typemax(Int) ÷ 2) : move!(b, pane, -typemax(Int) ÷ 2)
    elseif ev.key === :end || isplain(ev, 'G')
        pane === :doc ? step_doc!(b, typemax(Int) ÷ 2) : move!(b, pane, typemax(Int) ÷ 2)
    elseif ev.key === :left && ev.mods & ALT != 0 || isplain(ev, '[') || isalt(ev, 'b')
        go_back!(b)
    elseif ev.key === :right && ev.mods & ALT != 0 || isplain(ev, ']') || isalt(ev, 'f')
        go_forward!(b)
    elseif ev.key === :left || isplain(ev, 'h')
        focus_left!(b)
    elseif ev.key === :right || isplain(ev, 'l')
        focus_right!(b)
    elseif ev.key === :enter
        activate!(b, pane)
    elseif ev.key === :tab
        pane === :doc ? cycle_link!(b, 1) :
            (b.focus = pane === :side && side_placeholder(b) === nothing ? :names : :doc)
    elseif ev.key === :backtab
        pane === :doc ? cycle_link!(b, -1) :
            (b.focus = pane === :names || side_placeholder(b) !== nothing ? :side : :names)
    elseif ev.key === :backspace
        go_back!(b)
    elseif isctrl(ev, 'a')
        toggle_indirect!(b)
    elseif isctrl(ev, 't')
        toggle_textsearch!(b)
    elseif isplain(ev, 'x')
        key = current_key(b)
        key isa NameEntry ? toggle_flag!(b, :extended) : (b.status = "No extended help here")
    elseif isplain(ev, 'c')
        copy_place!(b)
    elseif isplain(ev, 't') || isplain(ev, 'T')
        current_key(b) === :start ? next_tip!(b, ev.char == 't' ? 1 : -1) : (b.status = "Tips are on the start page")
    elseif isplain(ev, '{')
        jump_heading!(b, -1)
    elseif isplain(ev, '}')
        jump_heading!(b, 1)
    elseif isplain(ev, 'w')
        b.layout = LAYOUTS[mod1(findfirst(==(b.layout), LAYOUTS) + 1, length(LAYOUTS))]
        LAYOUT[] = b.layout
        b.status = b.layout === :auto ? "Layout: fit the window" : "Layout: $(b.layout) pane" * (b.layout === :one ? "" : "s")
        clear_screen!(b)
    elseif isplain(ev, 'i')
        b.internal = !b.internal
        b.query === nothing ? refresh_names!(b) : update_search!(b)
        b.status = b.internal ? "Showing internal names" : "Hiding internal names"
    elseif isplain(ev, 'e')
        x = selected_subject(b)
        src = x === nothing ? page_source(b) : source_of(b, x)
        src === nothing ? (b.status = "No source location for that") : edit_source!(b, src)
    elseif isplain(ev, 'o')
        p = current_page(b)
        if b.link in eachindex(p.spots) && p.spots[b.link].target isa URLTarget
            open_url(b, p.spots[b.link].target.url)
        else
            b.status = "Pick a web link with ⇥ first"
        end
    elseif isplain(ev, 'y')
        code = pane === :doc ? code_at(b, b.doc_line) : nothing
        name = code === nothing ? current_name(b) : code.julia ? code.code : nothing
        if code !== nothing && !code.julia
            b.status = "Only Julia code goes to the prompt · ⏎ copies this"
        elseif name === nothing
            b.status = "Nothing to insert here"
        else
            b.result = name
            b.quit = true
        end
    elseif isplain(ev, 'a')
        all_open = all(r -> r in b.expanded, SECTION_ORDER)
        b.expanded = all_open ? Set(DEFAULT_EXPANDED) : Set(SECTION_ORDER)
        refresh_side!(b)
    elseif isctrl(ev, 'l')
        clear_screen!(b)
    else
        return false
    end
    return true
end

function handle!(b::Browser, ev::PasteEvent)
    text = strip(replace(valid_text(ev.text), r"\s+" => ' '))
    isempty(text) && return false
    # into the search being typed, where the cursor is, or else a new search
    if b.typing
        q = b.query
        set_query!(b, string(first(q, b.qcol), text, chop(q; head=b.qcol, tail=0)), b.qcol + length(text))
    else
        start_search!(b, String(text))
    end
    return true
end

# The terminal said whether it is dark or light, or what its background is. A background
# alone says dark or light only until the terminal says so outright.
function handle!(b::Browser, ev::SchemeEvent)
    if ev.dark !== nothing
        b.theme = ev.dark ? :dark : :light
    else
        bg = parse_colour(ev.background)
        bg === nothing && return false
        b.bg = bg
        b.theme === nothing && (b.theme = is_dark(bg) ? :dark : :light)
    end
    b.faces = browser_faces(b.theme, b.bg)
    b.prev = String[] # every row's colours may have changed
    return true
end

handle!(b::Browser, ev::CellSizeEvent) = (b.cell = (ev.height, ev.width); false)
handle!(b::Browser, ::AnsweredEvent) = (b.answered = true; false)

function send_logos!(b::Browser, pics::Vector{Picture})
    buf = IOBuffer()
    for pic in pics
        send_picture(buf, pic, logo_pixels(pic))
        push!(b.awaited, pic)
    end
    put(b, take!(buf))
    b.sent, b.gave_up = time(), false
end

# The terminal said that it draws pictures, so it is sent the browser's. Or it answered for
# one of them: it has taken it, and the picture can be drawn, or it could not draw it, and
# the picture is left out from then on.
function handle!(b::Browser, ev::GraphicsEvent)
    if ev.id == GRAPHICS_QUERY_ID
        ev.ok && isempty(b.awaited) && isempty(b.pictures) || return false
        send_logos!(b, [logo_picture(b.cell), mark_picture(b.cell)])
        Base.inferencebarrier(flush)(b.out)
        filter!(kv -> kv.first[1] !== :start, b.pages) # drawn without room for its picture
        return true
    end
    # iTerm2 answers for a picture sent in pieces without its number. Answers come in the
    # order the pictures were sent, so such an answer is for the first one still waiting.
    i = ev.id != 0 ? findfirst(pic -> pic.id == ev.id, b.awaited) : isempty(b.awaited) ? nothing : 1
    if i !== nothing
        pic = popat!(b.awaited, i)
        ev.ok && push!(b.pictures, pic)
    else
        # A picture it had taken, which it could not draw.
        j = ev.ok ? nothing : findfirst(pic -> pic.id == ev.id, b.pictures)
        j === nothing && return false
        deleteat!(b.pictures, j)
    end
    filter!(kv -> kv.first[1] !== :start, b.pages) # drawn with or without its picture
    return true
end

# The terminal lost the mouse encoding asked for, so it is asked for again.
function handle!(b::Browser, ::LegacyMouseEvent)
    b.live && put(b, "\e[?1000h\e[?1002h\e[?1003h\e[?1006h")
    return false
end

## Editing the search ##

# The keys that edit the query, as readline has them. ^A is the browser's.
function edit_query!(b::Browser, ev::KeyEvent)
    q = collect(b.query)
    n = clamp(b.qcol, 0, length(q))
    alt, ctrl = ev.mods == ALT, ev.mods == CTRL
    key(c) = ev.key === :char && ev.char == c
    if ev.key === :char && ev.mods & (CTRL | ALT) == 0
        isvalid(ev.char) || return false
        insert!(q, n + 1, ev.char)
        n += 1
    elseif ev.key === :backspace && ev.mods == 0
        n > 0 && (deleteat!(q, n); n -= 1)
    elseif ev.key === :delete || ctrl && key('d')
        n < length(q) && deleteat!(q, n + 1)
    elseif ev.key === :backspace && alt || ctrl && key('w')
        # Alt-Backspace takes a word of letters and digits, ^W one up to a space
        m = word_back(q, n, alt ? isalnum : !isspace)
        kill!(b, q, m+1:n)
        n = m
    elseif ctrl && key('u')
        kill!(b, q, 1:n)
        n = 0
    elseif ctrl && key('k')
        kill!(b, q, n+1:length(q))
    elseif alt && key('d')
        kill!(b, q, n+1:word_forward(q, n, isalnum))
    elseif ctrl && key('y')
        for c in b.killed
            insert!(q, n += 1, c)
        end
    elseif ev.key === :left && ev.mods == 0 || ctrl && key('b')
        n = max(0, n - 1)
    elseif ev.key === :right && ev.mods == 0 || ctrl && key('f')
        n = min(length(q), n + 1)
    elseif ev.key === :left && alt || alt && key('b')
        n = word_back(q, n, isalnum)
    elseif ev.key === :right && alt || alt && key('f')
        n = word_forward(q, n, isalnum)
    elseif ev.key === :home
        n = 0
    elseif ev.key === :end || ctrl && key('e')
        n = length(q)
    else
        return false
    end
    set_query!(b, String(q), n)
    return true
end

isalnum(c::Char) = isletter(c) || isdigit(c)

# Where the word before or after the first `n` characters of `q` starts or ends, over
# anything that is not in a word first.
function word_back(q, n, inword)
    while n > 0 && !inword(q[n]); n -= 1; end
    while n > 0 && inword(q[n]); n -= 1; end
    return n
end
function word_forward(q, n, inword)
    while n < length(q) && !inword(q[n+1]); n += 1; end
    while n < length(q) && inword(q[n+1]); n += 1; end
    return n
end

function kill!(b::Browser, q::Vector{Char}, r::UnitRange{Int})
    isempty(r) && return
    b.killed = String(q[r])
    deleteat!(q, r)
end

function set_query!(b::Browser, q::String, col::Int)
    b.qcol = col
    q == b.query && return
    b.query = q
    update_search!(b)
end

function hit_at(b::Browser, row::Int, col::Int)
    for h in Iterators.reverse(b.hits)
        h.row == row && col in h.cols && return h
    end
    return nothing
end

function pane_at(b::Browser, row::Int, col::Int)
    3 <= row <= b.height - 1 || return nothing
    for (pane, x, w) in layout(b)
        x <= col < x + w && return pane
    end
    return nothing
end

function handle!(b::Browser, ev::MouseEvent)
    b.console === nothing || !isempty(b.loading) || ev.action !== :press || (b.console = nothing; return true)
    if b.dragging && ev.action === :drag
        return drag_selection!(b, ev.row, ev.col)
    elseif b.dragging && ev.action === :release
        return release_selection!(b)
    elseif ev.action === :move || ev.action === :drag
        h = hit_at(b, ev.row, ev.col)
        if ev.action === :drag && h !== nothing && h.action isa Tuple && first(h.action) === :scrollbar
            return click!(b, h, false)
        end
        hover = h === nothing ? nothing : h.action
        pt = doc_point(b, ev.row, ev.col)
        block = pt === nothing ? 0 : code_block_start(current_page(b), pt[1])
        moved = block != b.pointer_block
        b.pointer_block = block
        # Moving onto the card keeps it, and what it previews.
        hover == (:card,) && return moved
        hover == b.hover && return moved
        hide_card!(b)
        b.hover = hover
        b.hover_at = (ev.row, ev.col)
        rest_pointer!(b)
        return true
    elseif ev.action in (:wheelup, :wheeldown)
        hide_card!(b)
        pane = pane_at(b, ev.row, ev.col)
        pane === nothing && return false
        delta = ev.action === :wheelup ? -3 : 3
        if pane === :doc
            scroll_doc!(b, delta)
        else
            ls = list_state(b, pane)
            len = list_length(b, pane)
            len -= list_offset(b, pane)
            ls.scroll = clamp(ls.scroll + delta, 0, max(0, len - list_rows(b, pane)))
        end
        return true
    elseif ev.action === :press
        ev.button in (8, 9) && (b.help = false)
        ev.button == 8 && return go_back!(b)
        ev.button == 9 && return go_forward!(b)
        # Terminals do not report Cmd, so right-click, Alt-click and Ctrl-click open the source.
        if ev.button == 3 || (ev.button == 1 && ev.mods & (ALT | CTRL) != 0)
            h = hit_at(b, ev.row, ev.col)
            return edit_subject!(b, h === nothing ? nothing : hit_subject(b, h.action))
        end
        ev.button == 1 || return false
        b.status = ""
        b.sel = nothing
        FIRST_OPEN[] = false
        h = hit_at(b, ev.row, ev.col)
        h !== nothing && h.action == (:console,) && return false
        if h !== nothing && h.action == (:card,) && b.card !== nothing
            subject = b.card[2]
            hide_card!(b)
            subject isa NameEntry ? open_entry!(b, subject) : follow!(b, subject)
            return true
        end
        hide_card!(b)
        # Clicking anywhere but the search field ends typing in it.
        (h === nothing || !(first(h.action)::Symbol in (:search, :toggle_text))) && (b.typing = false)
        # Anything that navigates closes the help, so what it shows is not hidden underneath.
        h === nothing || first(h.action)::Symbol in (:help, :scrollbar, :spot) || (b.help = false)
        if h === nothing
            press_doc!(b, ev.row, ev.col) && return true
            pane = pane_at(b, ev.row, ev.col)
            pane === nothing || (pane === :names && side_placeholder(b) !== nothing) || (b.focus = pane)
            b.help = false
            return true
        end
        now = time()
        double = b.last_click[2] == h.action && now - b.last_click[1] < 0.4
        b.last_click = (now, h.action)
        return click!(b, h, double)
    end
    return false
end

function click!(b::Browser, h::Hit, double::Bool)
    a = h.action
    kind = first(a)::Symbol
    if kind in (:side, :names)
        pane, i = a::Tuple{Symbol,Int}
        b.help = false
        ls = list_state(b, pane)
        again = b.focus === pane && ls.cursor == i
        ls.cursor = i
        b.focus = pane
        b.source = pane
        b.override = nothing
        pane === :side && sync_side!(b)
        pane === :names && show_heading!(b)
        header = pane === :side ? is_header(b.side_rows[i]) : b.name_rows[i].kind in (:header, :page)
        (header || double || (again && pane === :names)) && activate!(b, pane)
    elseif kind === :section
        follow!(b, SectionTarget(a[2]))
    elseif kind === :spot
        p = current_page(b)
        _, k = a
        k in eachindex(p.spots) || return false
        # A link in the help leaves the help, for the page underneath.
        b.help ? (b.help = false) : (b.link = k)
        follow!(b, p.spots[k].target)
    elseif kind === :scrollbar
        p = current_page(b)
        b.doc_scroll = round(Int, a[2] * max(0, length(p.lines) - content_rows(b)))
    elseif kind === :crumb
        m = a[2]
        m === b.mod && b.query === nothing && return false
        navigate!(b) do
            b.focus = :names
            show_module!(b, m)
        end
    elseif kind === :load
        load_package!(b, a[2])
    elseif kind === :project
        follow!(b, SectionTarget(:direct))
    elseif kind === :toggle_text
        toggle_textsearch!(b)
        b.query === nothing && start_search!(b)
    elseif kind === :copylink
        copy_place!(b)
    elseif kind === :focus
        a[2] === :names && side_placeholder(b) !== nothing && return false
        b.focus = a[2]
    elseif kind === :back
        go_back!(b)
    elseif kind === :forward
        go_forward!(b)
    elseif kind === :search
        start_search!(b, something(b.query, ""))
    elseif kind === :help
        b.help = !b.help
    elseif kind === :quit
        b.quit = true
    elseif kind === :key
        return handle!(b, a[2])
    end
    return true
end

## Help ##

const HELP_TEXT = """
This browser shows Julia's manual, under *Julia*, and the loaded packages, under *Packages*. Each library is one row: select it to list the pages of its manual, if its source has one, and then its names. A package with no module docstring shows its README instead. A package's page links to its full documentation online as *docs*. Julia's manual is also at <$(julia_docs())>.

# Moving around

  * `↑` `↓` or `j` `k`: move in a list, or scroll the documentation.
  * `←` `→` or `h` `l`: move between the panes. In a submodule, `←` goes up to its parent.
  * `⏎`: open what is selected. On a section heading, fold or unfold it.
  * `⇥` and `⇧⇥` in the documentation: step through its links. `⏎` follows the selected link.
  * `⌫`, `[` or `Alt-←`: go back. `]` or `Alt-→`: go forward.
  * `PgUp` `PgDn` `Space` `g` `G`: page up and down, top and bottom.
  * `{` `}`: jump to the previous or next heading. Long pages start with a list of their headings.
  * `x`: show or hide the extended help of a docstring.
  * `t` `T` on the start page: show the next or the previous tip.
  * `c`: copy a link to this place, such as `help?> docs: manual/performance-tips`. Pasted at
    the `julia>` prompt, it opens the browser here. The address of a page of the online docs
    works there too.
  * `w`: change the layout: three panes, two, one, or fit the window.

# Finding things

  * `/`: search everything: the names of every loaded module first, then the manual and the text of
    docstrings, and the names that the manuals of packages that are not loaded list. `Plots.pl`
    searches inside modules matching `Plots`.
  * While typing a search, the readline keys edit it: `←` `→`, `Home` `End`, `^W`, `^K`, `^Y`,
    `Alt-⌫`. `→` at its end goes on to the results.
  * `Ctrl-T`: search only names, then only text, then everything again.
  * `Ctrl-A`: include indirect dependencies in searches, or leave them out again.
  * `i`: show or hide internal (non-public) names.
  * `a`: unfold every package section, including indirect dependencies.

# Leaving the browser

  * `y`: close the browser and put the name being viewed at the REPL prompt. On a line of Julia
    code, it puts that block of code there instead, as only its input when it is an example.
  * ⧉, beside a block of code: copy the code, as only its input when it is an example.
  * `e`: open the source of the selected link or name, or else of the page, in your editor.
  * Right-click, `Alt`-click or `Ctrl`-click: open the source of what is under the pointer.
  * `o`: open the selected web link in your web browser.
  * `q` or `Esc`: close the browser.

# The mouse

Click to select, and click again (or double-click) to open. Click links to follow them, and the breadcrumbs at the top to go up. The wheel scrolls the pane under the pointer, and the back and forward mouse buttons move through history.

Drag across the documentation to select text, which is copied when you let go. Double-click selects a word, and triple-click a line. To select with your terminal instead, hold NATIVE_KEY while you drag.

# What the marks mean

  * `●` exported: available after `using`.
  * `○` public: part of the API, but needs qualifying, as in `Module.name`.
  * `·` internal: not public, and may change without notice.

Dimmed names are internal, and struck-out names are deprecated. Mentions of packages, such as `Example.jl`, lead to the package's documentation, to its load page, or to a web search.

# More help

At the REPL, type `?` followed by a name for its documentation, `;` for a shell, and `]` to manage packages.
"""

function help_page(cat::Catalog, width::Int)
    pb = PageBuilder(width)
    addline!(pb)
    add_markdown!(pb, Markdown.parse(replace(HELP_TEXT, "NATIVE_KEY" => native_select_key())), Base, cat)
    addline!(pb)
    return Page(pb)
end

## Entry point ##

const LAYOUT = Ref(:auto)
# Where the browser was when it last closed, so that it opens there again.
const LAST = Ref{Any}(nothing)

"""
    browse([term]; query=nothing, context=Main) -> Union{String, Nothing}
    browse([term,] x)

Open the documentation browser on `term`. It shows Julia's manual, and every loaded module,
split into the active project's dependencies, the indirect dependencies and standard
libraries, and Julia's own modules, along with each module's names and their documentation.

`query` picks where to start: a place in the docs, such as `"docs: manual/variables"` or the
address of a page of the online docs, opens there; a name such as `"sum"` or
`"Base.Iterators"` opens its documentation; and anything else starts a search. Passing an object `x` instead opens the
documentation of `x`: a module, a function, a type, or else the type of `x`. With neither,
the browser opens where it was last closed.

Returns the name or the code chosen with `y`, or `nothing`.
"""
function browse(term::REPL.Terminals.TextTerminal = REPL.TerminalMenus.default_terminal();
                query::Union{Nothing,AbstractString} = nothing, context::Module = Main)
    b = opening(term)
    query === nothing || (query = valid_text(query))
    if query !== nothing && !isempty(strip(query))
        t = something(place_target(query, b.cat), resolve_ref(query, context, b.cat), Some(nothing))
        if t === nothing || t isa URLTarget
            start_search!(b, String(strip(query)))
        else
            follow!(b, t)
            empty!(b.back)
        end
    else
        reopen!(b)
    end
    return run!(b)
end

browse(x; context::Module = Main) = browse(REPL.TerminalMenus.default_terminal(), x; context)

function browse(term::REPL.Terminals.TextTerminal, x; context::Module = Main)
    x isa AbstractString && return browse(term; query = x, context)
    b = opening(term)
    t = object_target(x)
    if t !== nothing
        follow!(b, t)
        empty!(b.back)
    end
    return run!(b)
end

function object_target(@nospecialize x)
    x isa Module && return ModuleTarget(x)
    if x isa Function
        m, s = parentmodule(x), nameof(x)
        visible_binding(m, s) && getglobal(m, s) === x && return NameTarget(m, s)
    end
    return type_target(x isa Type ? x : typeof(x))
end

function reopen!(b::Browser)
    last = LAST[]
    last === nothing && return
    mod, name, focus = last
    # The module may be gone since, or no longer have the name.
    @attempt begin
        show_module!(b, mod; entry = name)
        b.focus = focus
        focus === :side && (b.source = :side)
    end
end

function await_release(io::IO)
    while true
        ev = try
            read_event(io)
        catch err
            err isa EOFError || rethrow()
            return
        end
        ev isa MouseEvent && ev.action in (:drag, :move) && continue
        return
    end
end

# Read the terminal's reports at the front of the input, waiting `wait` seconds for each, and
# leave whatever else was typed for the prompt.
function drain_reports(io::IO, wait::Float64=0.05)
    try
        while wait_bytes(io, wait)
            dynamic(mark)(io)
            head = UInt8[]
            while length(head) < 3 && wait_bytes(io, 0.03)
                push!(head, read(io, UInt8))
            end
            dynamic(reset)(io)
            # a mouse report, or an answer about a picture
            head == b"\e[<" || head == b"\e_G" || return
            read_event(io)
        end
    catch err
        err isa EOFError || rethrow()
    end
end

# Drawn with `rich_faces` when the terminal allows, except where the user has set a face.
# With more than one thread, the browser runs on another, so that it keeps responding while a
# package loads. Packages load on the thread that opened the browser, which in the REPL is the
# main thread: some, such as GLFW, can only be loaded there.
function run!(b::Browser)
    Threads.nthreads() > 1 || return run_here!(b)
    b.loads = Channel{Task}(Inf)
    t = Threads.@spawn :default try
        run_here!(b)
    finally
        close(b.loads)
    end
    # scheduled from here, so that they run on this thread
    for load in b.loads
        schedule(load)
    end
    try
        return fetch(t)
    catch err
        err isa TaskFailedException && throw(err.task.exception)
        rethrow()
    finally
        b.loads = nothing
    end
end

function run_here!(b::Browser)
    !Base.generating_output() && !any(p -> p.role === :manual, b.cat.manual) && download_manual!(b)
    autodownload!(b)
    run_screen!(b)
end

# The rich faces for `theme` and `bg`, except where the user has set a face.
function browser_faces(theme, bg)
    custom = hasproperty(StyledStrings.FACES, :modifications) ? values(StyledStrings.FACES.modifications) : ()
    return Pair{Symbol,Face}[kv for kv in rich_faces(theme, bg) if !any(m -> haskey(m, kv[1]), custom)]
end

function download_manual!(b::Browser)
    start_manual_download() do
        @lock b.lock begin
            b.cat.manual = manual_pages()
            b.cat.anchors = b.cat.sections = nothing
            empty!(b.cat.index_headings)
            empty!(b.pages)
            refresh_side!(b)
            b.quit || draw(b)
        end
    end
    # so that the sidebar and the Manual section show that it is downloading
    @lock b.lock begin
        empty!(b.pages)
        refresh_side!(b)
    end
end

# Download the manual of the package whose page is shown, which it was installed without.
function fetch_docs!(b::Browser)
    key = current_key(b)
    id, dir = key isa ModuleTarget ? (PkgId(key.mod), pkgdir(key.mod)) :
              key isa LoadTarget ? (key.id, unloaded_dir(key.id)) : (nothing, nothing)
    (id === nothing || dir === nothing) && return
    b.status = "Downloading $(id.name)'s manual from its repository…"
    downloader()
    errormonitor(Threads.@spawn begin
        msg = try
            dynamic(fetch_package_docs)(id, dir)
            "Downloaded $(id.name)'s manual"
        catch err
            err isa InterruptException && rethrow()
            "Could not download $(id.name)'s manual: " * first_line(err) *
                " · DocBrowser.explain_docs(\"$(id.name)\"; online=true) says more"
        end
        manuals_changed!(b; status=msg)
    end)
    return
end

# Show the manuals that have been downloaded since the pages were made.
function manuals_changed!(b::Browser; status::Union{Nothing,String}=nothing, note::Union{Nothing,String}=nothing)
    @lock b.lock begin
        empty!(b.cat.pkgdocs)
        b.cat.manuals = nothing
        b.cat.docs_dirs = (0, Tuple{String,PkgEntry}[])
        empty!(b.pages)
        refresh_side!(b)
        # the pages of a package's manual are listed with its names
        refresh_names!(b)
        status === nothing || (b.status = status)
        note === nothing || (b.fetch_note = note)
        b.quit || draw(b)
    end
    return
end

# Download, in the background, the manuals of the packages the browser lists that are installed
# without them, saying so in the footer. It never stands in the way: what fails is tried again
# another day, and `explain_docs` says why.
function autodownload!(b::Browser)
    (autodownload_enabled() && !Base.generating_output()) || return
    @lock DOWNLOAD_LOCK (AUTODOWNLOADING[] && return; AUTODOWNLOADING[] = true)
    pkgs, unloaded = @lock b.lock (copy(b.cat.pkgs), copy(b.cat.unloaded))
    task = Threads.@spawn try
        # Working out what to download loads Pkg, which can hold up the browser for a moment,
        # so that waits for a pause in the typing.
        while time() - LAST_INPUT[] < 1.0 && !b.quit
            sleep(0.25)
        end
        wanted = dynamic(packages_wanting_manuals)(pkgs, unloaded)
        isempty(wanted) && return
        # said once it is known which of them have a manual to look for
        names = Ref("")
        start(ns) = (names[] = join(first(ns, 3), ", ") * (length(ns) > 3 ? " and $(length(ns) - 3) more" : "");
                     manuals_changed!(b; note="Downloading the manuals of $(names[])…"))
        progress(done, total) = done < total &&
            manuals_changed!(b; note="Downloading the manuals of $(names[]) ($done of $total repositories)…")
        got = dynamic(fetch_manuals)(wanted; start, progress)::Int
        manuals_changed!(b; note="", status=got == 0 ? nothing :
            "Downloaded the manuals of $got package$(got == 1 ? "" : "s")")
    catch err
        err isa InterruptException && rethrow()
        @debug "Downloading manuals failed" exception=(err, catch_backtrace())
        @lock b.lock (b.fetch_note = "")
    finally
        @lock DOWNLOAD_LOCK AUTODOWNLOADING[] = false
    end
    @lock DOWNLOAD_LOCK AUTODOWNLOAD[] = task
    return
end

# Draw again if the terminal has changed size, or it is time for a card to show.
function tick(b::Browser)
    @lock b.lock try
        b.quit || ((check_size!(b) | in_world(show_card!, b)::Bool) && in_world(draw, b))
    catch err
        # shown by the next draw, as for a key that fails
        b.status = "Error: " * first_line(err)
    end
    return
end

# Call `f` when the terminal changes size. Julia tells of this from 1.14; before that the
# size is looked at 20 times a second.
@static if isdefined(Base, :SignalCondition)
    watch_resize(f) = Base.SignalCondition(_ -> f(), Base.SIGWINCH)
else
    watch_resize(f) = Timer(_ -> f(), 0.05; interval=0.05)
end

function run_screen!(b::Browser)
    enter_screen(b)
    b.live = true
    timer = watch_resize(() -> tick(b))
    # The first frame waits for the terminal to say whether it draws pictures, so that it
    # does not change as soon as it shows. The terminal was asked before the browser was
    # made, so it has mostly answered already. A key typed ahead ends the wait, as it is
    # meant for the frame.
    settling = true
    deadline = time() + SETTLE_WAIT
    pending = false
    try
        while !b.quit
            if settling
                settling = !b.answered && time() < deadline && wait_bytes(b.in, deadline - time()) &&
                    peek(b.in, UInt8) == 0x1b
                settling || @lock b.lock (draw(b); pending = false)
            end
            ev = try
                read_event(b.in)
            catch err
                err isa EOFError || rethrow()
                break
            end
            LAST_INPUT[] = time()
            ev === nothing && continue
            @lock b.lock begin
                changed = try
                    in_world(handle!, b, ev)::Bool
                catch err
                    err isa InterruptException && rethrow()
                    b.status = "Error: " * first_line(err)
                    true
                end
                b.quit && stay_open!(b)
                # During a burst, of wheel turns or a held key, the frame is drawn once, at its end.
                pending |= changed
                if pending && !settling && !b.quit && bytesavailable(b.in) == 0
                    in_world(draw, b)
                    pending = false
                end
            end
            # A click that closes the browser is followed by its release, which would
            # otherwise be typed at the prompt.
            b.quit && ev isa MouseEvent && ev.action === :press && await_release(b.in)
        end
    finally
        # Stop anything else drawing, also when leaving on an error.
        @lock b.lock (b.quit = true; b.live = false; stop_card_timer!(b))
        close(timer)
        # Pointer moves are reported until the terminal sees the end of mouse reporting,
        # so some may still be on their way, however the browser was closed.
        leave_screen(b, true)
    end
    key = current_key(b)
    LAST[] = (b.mod, key isa NameEntry ? key.name : nothing, b.focus)
    return b.result
end
