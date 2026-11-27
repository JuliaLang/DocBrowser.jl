# Pages: rendered documentation, as lines of styled text plus the links on them.

struct ModuleTarget
    mod::Module
end
struct NameTarget
    mod::Module
    name::Symbol
end
struct URLTarget
    url::String
    URLTarget(url) = new(as_string(url))
end
struct SourceTarget
    file::String
    line::Int
    SourceTarget(file, line::Int) = new(as_string(file), line)
end
struct SectionTarget
    role::Symbol
end
struct LoadTarget
    id::PkgId
    then::String # a name in the package to open once it is loaded, or ""
end
LoadTarget(id::PkgId) = LoadTarget(id, "")
struct AnchorTarget
    heading::Int # counts the page's headings from the top
end
struct ToggleTarget
    flag::Symbol # a section of the page to show or hide: :extended or :methodswith
end
struct CodeTarget
    code::String
    julia::Bool # whether it is Julia code, which can be put at the prompt
end
CodeTarget(code) = CodeTarget(code, true)
struct ManualTarget
    path::String   # a page of the manual
    anchor::String # the `@id` or text of one of its headings, or "" for its top
    ManualTarget(path, anchor) = new(as_string(path), as_string(anchor))
end

const Target = Union{ModuleTarget,NameTarget,URLTarget,SourceTarget,SectionTarget,LoadTarget,
                     AnchorTarget,ToggleTarget,CodeTarget,ManualTarget}

"""
    Spot

A clickable stretch of a page: display columns `cols` of line `line`, leading to `target`.
"""
struct Spot
    line::Int
    cols::UnitRange{Int}
    target::Target
end

"""
    Picture

An image that the terminal holds under the number `id`, of `width` by `height` pixels. It is
drawn over `cols` by `rows` cells.
"""
struct Picture
    id::Int
    cols::Int
    rows::Int
    width::Int
    height::Int
end

# A picture on a page, by the line and column of its top left cell. The page leaves the cells
# under it blank. `file` is the PNG file it is read from, or empty for one the browser draws.
struct PageImage
    line::Int
    col::Int
    picture::Picture
    file::String
end
PageImage(line::Int, col::Int, picture::Picture) = PageImage(line, col, picture, "")

"""
    PictureSupport

What a page needs to know to make room for pictures from files: the height and width of
the terminal's cells, and the numbers of the pictures it could not draw. `images` is where
DocBrowserImages is: `:absent`, `:installed`, `:loading`, `:loaded` or `:failed`, and a page
with an image that only it reads sets `wanted`.
"""
struct PictureSupport
    cell::Tuple{Int,Int}
    refused::Set{Int}
    images::Symbol
    wanted::Base.RefValue{Bool}
end

# A box on a page where an image of the format `format` will be drawn once DocBrowserImages
# has read it: `rows` lines from `line`, `cols` columns from `col`.
struct ImageHolder
    line::Int
    col::Int
    rows::Int
    cols::Int
    format::String
end

struct Page
    lines::Vector{AnnotatedString{String}}
    spots::Vector{Spot}
    source::Union{Nothing,SourceTarget}
    headings::Vector{Int}
    images::Vector{PageImage}
    holders::Vector{ImageHolder}
end

struct PageBuilder
    lines::Vector{AnnotatedString{String}}
    spots::Vector{Spot}
    width::Int
    images::Vector{PageImage}
    holders::Vector{ImageHolder}
    pictures::Union{Nothing,PictureSupport} # nothing where the terminal draws no pictures
end
PageBuilder(width::Int, pictures::Union{Nothing,PictureSupport}=nothing) =
    PageBuilder(AnnotatedString{String}[], Spot[], width, PageImage[], ImageHolder[], pictures)

Page(pb::PageBuilder, source=nothing) =
    Page(pb.lines, sort_by!(pb.spots, s -> (s.line, first(s.cols))), source, heading_lines(pb.lines), pb.images, pb.holders)

is_heading_face(v) = v isa Symbol && startswith(String(v), "markdown_h") && v !== :markdown_hrule

# The lines that hold Markdown headings, leaving out the lines that underline them.
function heading_lines(lines)
    out = Int[]
    inside = false # whether the line before is part of a heading
    for (i, l) in enumerate(lines)
        if !any(a -> a.label === :face && is_heading_face(a.value), annotations(l))
            inside = false
            continue
        end
        # Underlines are drawn with a different character at each level, but never letters.
        text = strip(String(l))
        any(c -> isletter(c) || isdigit(c), text) || continue
        # A long heading wraps onto more lines, but is one heading.
        inside || push!(out, i)
        inside = true
    end
    return out
end

# A tab has no width of its own, so it would put clicks and selections in the wrong column.
# A space is one byte too, so the annotations still line up.
untab(s::AnnotatedString{String}) =
    '\t' in String(s) ? AnnotatedString(replace(String(s), '\t' => ' '), annotations(s)) : s

const Annotations = typeof(annotations(AnnotatedString("")))

# The parts joined into one annotated string. `annotatedstring` does the same for any
# arguments, but packages that add string types invalidate its compiled code, and with it
# the code that draws every row.
function concat(parts...)
    io = IOBuffer()
    anns = Annotations()
    for p in parts
        off = position(io)
        p isa SubString{AnnotatedString{String}} && (p = dynamic(AnnotatedString)(p)::AnnotatedString{String})
        if p isa AnnotatedString{String}
            write(io, p.string)
            for a in annotations(p)
                push!(anns, (region=a.region .+ off, label=a.label, value=a.value))
            end
        elseif p isa String
            write(io, p)
        else
            write(io, String(p)::String)
        end
    end
    return AnnotatedString(String(take!(io)), anns)
end

function styled(text, face)
    str = text isa AnnotatedString{String} || text isa SubString{AnnotatedString{String}} ?
        dynamic(AnnotatedString)(text)::AnnotatedString{String} : AnnotatedString(as_string(text))
    s = untab(str)
    isempty(s) || face === nothing || face!(s, face)
    return s
end

# A segment is plain text, or `(text, face)`, or `(text, face, target)` for a link.
segment(x::AbstractString) = (x, nothing, nothing)
segment(x::Tuple) = (x[1], x[2], length(x) > 2 ? x[3] : nothing)

function addline!(pb::PageBuilder, segs...)
    parts = AnnotatedString{String}[]
    col = 1
    row = length(pb.lines) + 1
    for seg in segs
        text, face, target = segment(seg)
        s = styled(text, target === nothing ? face : something(face, :REPL_DocBrowser_link))
        w = textwidth(String(s))
        w > 0 && target !== nothing && push!(pb.spots, Spot(row, col:col+w-1, target))
        col += w
        push!(parts, s)
    end
    push!(pb.lines, isempty(parts) ? AnnotatedString("") : concat(parts...))
    return pb
end

"""
    addflow!(pb, indent, segs)

Add `segs` as a paragraph, breaking lines between segments to fit the page width.
A vector of segments stays together on one line.
"""
function addflow!(pb::PageBuilder, indent::String, segs::Vector)
    line = Any[indent]
    used = textwidth(indent)
    for seg in segs
        group = seg isa Vector ? seg : Any[seg]
        w = sum(s -> textwidth(String(segment(s)[1])), group; init=0)::Int
        if used + w > pb.width && length(line) > 1
            addline!(pb, line...)
            line = Any[indent]
            used = textwidth(indent)
        end
        append!(line, group)
        used += w
    end
    length(line) > 1 && addline!(pb, line...)
    return pb
end

# Add `text` as a paragraph that wraps between its words.
function addtext!(pb::PageBuilder, indent::String, text::String, face=nothing)
    segs = Any[]
    for w in eachsplit(text)
        push!(segs, (w * " ", face))
    end
    return addflow!(pb, indent, segs)
end

rule!(pb::PageBuilder) = addline!(pb, ("  " * "─"^max(0, pb.width - 4), :REPL_DocBrowser_border))

function heading!(pb::PageBuilder, title::String)
    addline!(pb)
    addline!(pb, "  ", (title, :REPL_DocBrowser_section))
end

## Markdown ##

function render_markdown(md, width::Int)
    # Wrapping the buffer in an `IOContext` would lose the annotations.
    buf = AnnotatedIOBuffer()
    if md isa Markdown.MD
        Markdown.term(buf, md, width)
    else
        show(buf, MIME"text/plain"(), md)
    end
    return split_lines(dynamic(read)(seekstart(buf), AnnotatedString)::AnnotatedString{String})
end

# The lines of `str`, each with its part of the annotations. Splitting the annotated text
# itself looks through every annotation for every character, which is slow on a long page.
function split_lines(str::AnnotatedString{String})
    s = String(str)
    starts, stops = Int[1], Int[]
    i = 1
    while (j = findnext('\n', s, i)) !== nothing
        push!(stops, prevind(s, j))
        push!(starts, j + 1)
        i = j + 1
    end
    push!(stops, lastindex(s))
    anns = annotations(str)
    per_line = [similar(anns, 0) for _ in starts]
    for a in anns
        k = searchsortedlast(starts, first(a.region))
        while 1 <= k <= length(starts) && starts[k] <= last(a.region)
            lo, hi = max(first(a.region), starts[k]), min(last(a.region), stops[k])
            lo <= hi && push!(per_line[k], (; region = lo-starts[k]+1:hi-starts[k]+1, label = a.label, value = a.value))
            k += 1
        end
    end
    return AnnotatedString{String}[AnnotatedString(s[starts[k]:stops[k]], per_line[k]) for k in eachindex(starts)]
end

function walk_md(f, @nospecialize(x))
    f(x)
    if x isa AbstractVector
        for y in x
            walk_md(f, y)
        end
    elseif x isa Markdown.MD
        walk_md(f, x.content)
    elseif parentmodule(typeof(x)) === Markdown
        for field in fieldnames(typeof(x))
            isdefined(x, field) || continue
            v = getfield(x, field)
            (v isa AbstractVector || parentmodule(typeof(v)) === Markdown) && walk_md(f, v)
        end
    end
end

md_text(x::AbstractString) = as_string(x)
md_text(x::Markdown.Code) = x.code
md_text(x::Markdown.LaTeX) = x.formula
md_text(x::AbstractVector) = sprint(io -> foreach(y -> print(io, md_text(y)::String), x))
md_text(@nospecialize(x)) = hasfield(typeof(x), :text) ? md_text(getfield(x, :text)) : ""

"""
    ref_targets(md) -> Dict{String,String}

Map the text of each `[text](@ref target)` link in `md` to the name it refers to.
"""
function ref_targets(md)
    refs = Dict{String,String}()
    walk_md(md) do x
        x isa Markdown.Link || return
        startswith(x.url, "@ref") || return
        text = strip(replace(md_text(x.text)::String, r"\s+" => ' '))
        target = strip(chopprefix(x.url, "@ref"), [' ', '`'])
        refs[text] = isempty(target) ? text : target
    end
    return refs
end

valid_name_part(p::AbstractString) = Base.isidentifier(p) || Base.isoperator(Symbol(p)) ||
    (startswith(p, '@') && Base.isidentifier(p[2:end]))

"""
    resolve_ref(text, ctx, cat) -> Union{Target, Nothing}

Find what a code span such as `sort!`, `Base.Iterators` or `sum(f, A)` refers to, looking
in `ctx`, then `Main`, then `Base`. Only documented or public names count, so that code
spans which merely mention a variable do not become links.
"""
function resolve_ref(text::AbstractString, ctx::Module, cat::Catalog)
    s = strip(text)
    i = findfirst(in("({[ "), s)
    # A name then a space is a command or an expression, as in `mv a b` or `float = false`,
    # unless it is a macro and what it is given.
    i === nothing || s[i] != ' ' || startswith(s, '@') || return nothing
    i === nothing || (s = s[1:prevind(s, i)])
    isempty(s) && return nothing
    parts = split(s, '.')
    is_name_path(parts) || return nothing
    for root in unique!(Module[ctx, Main, Base])
        t = resolve_path(root, parts, cat)
        t === nothing || return t
    end
    return nothing
end

# Whether `parts` can be a name with the modules it is in before it.
is_name_path(parts) = all(p -> !isempty(p) && Base.isidentifier(p), @view parts[1:end-1]) &&
    valid_name_part(parts[end])

visible_binding(m::Module, s::Symbol) = isdefined(m, s) && !Base.isdeprecated(m, s)

# The module that the last of `parts` is a name in, going from `root` through the modules
# before it, and that name, or `nothing` if there is no such name.
function find_binding(root::Module, parts)
    m = root
    for p in @view parts[1:end-1]
        sym = Symbol(p)
        visible_binding(m, sym) || return nothing
        v = getglobal(m, sym)
        v isa Module || return nothing
        m = v
    end
    sym = Symbol(parts[end])
    return visible_binding(m, sym) ? (m, sym) : nothing
end

function resolve_path(root::Module, parts, cat::Catalog)
    found = find_binding(root, parts)
    found === nothing && return nothing
    m, sym = found
    v = getglobal(m, sym)
    v isa Module && return ModuleTarget(v)
    b = Binding(m, sym)
    public = Base.ispublic(m, sym)
    (public || b in cat.documented) || return nothing
    return NameTarget(public ? m : b.mod, sym)
end

function find_spots!(spots::Vector{Spot}, row::Int, line::AnnotatedString, ctx::Module,
                     refs::Dict{String,String}, cat::Catalog)
    str = String(line)
    anns = sort_by!(copy(annotations(line)), a -> a.label !== :link)
    taken = UnitRange{Int}[]
    for ann in anns
        r = first(ann.region):thisind(str, last(ann.region))
        isempty(r) && continue
        target = if ann.label === :link && ann.value isa AbstractString
            url = as_string(ann.value)
            # an `@ref` that leads nowhere the browser knows
            startswith(url, '@') ? nothing :
                is_manual_link(url) ? manual_target(url) : something(pkgdocs_target(url), URLTarget(url))
        elseif ann.label === :face && (ann.value === :markdown_inlinecode || ann.value === :markdown_link)
            text = strip(str[r])
            resolve_ref(get(refs, text, text), ctx, cat)
        end
        target === nothing && continue
        col = textwidth(SubString(str, 1, prevind(str, first(r)))) + 1
        cols = col:col+textwidth(str[r])-1
        any(c -> !isempty(intersect(c, cols)), taken) && continue
        push!(taken, cols)
        push!(spots, Spot(row, cols, target))
    end
    # Mentions of packages, such as `Revise.jl`. Package names start with a capital letter, and
    # in code, or after a `/`, such a name is the name of a file.
    is_code_line(line) && return
    for m in eachmatch(r"(?<![\w./])([A-Z][A-Za-z0-9_]*)\.jl\b", str)
        r = m.offset:(m.offset + ncodeunits(m.match) - 1)
        col = textwidth(SubString(str, 1, prevind(str, first(r)))) + 1
        cols = col:col+textwidth(m.match)-1
        any(c -> !isempty(intersect(c, cols)), taken) && continue
        push!(taken, cols)
        push!(spots, Spot(row, cols, mention_target(cat, m[1])))
    end
end

const DEFAULT_SEARCH_URL = "https://duckduckgo.com/?q=%s"

# Percent-encode everything but the characters that URLs leave unreserved.
escape_query(q::AbstractString) =
    join(c in 'A':'Z' || c in 'a':'z' || c in '0':'9' || c in "-._~" ? string(c) :
         join(("%" * uppercase(string(b; base=16, pad=2)) for b in codeunits(string(c)))) for c in q)

"""
    web_search(name) -> URLTarget

A web search for package `name`. The search engine comes from the
`JULIA_DOCBROWSER_SEARCH_URL` environment variable, a URL with `%s` where the query goes.
"""
function web_search(name::AbstractString)
    template = get(ENV, "JULIA_DOCBROWSER_SEARCH_URL", "")
    occursin("%s", template) || (template = DEFAULT_SEARCH_URL)
    return URLTarget(replace(template, "%s" => escape_query(name * ".jl")))
end

# Where a mention of package `name` leads: its docs when loaded, its load page when it is a
# project dependency, and otherwise a web search.
function mention_target(cat::Catalog, name::AbstractString)
    t = package_target(cat, name)
    t === nothing || return t
    for id in cat.unloaded
        id.name == name && return LoadTarget(id)
    end
    return web_search(name)
end

"""
    add_markdown!(pb, md, ctx, cat; contents=false, dirs=String[])

Render `md`, making links of the names it mentions, which are looked up from module `ctx`.
Blocks of code get a ⧉ that copies them. With `contents`, a page with several
headings starts with links to them. An image that is a paragraph of its own is drawn as a
picture, where the terminal draws them and the image is a PNG file in one of `dirs`.
"""
function add_markdown!(pb::PageBuilder, md, ctx::Module, cat::Catalog; contents::Bool=false,
                       dirs::Vector{String}=String[])
    refs = ref_targets(md)
    marks = pb.pictures === nothing || isempty(dirs) || !(md isa Markdown.MD) ? PictureMark[] :
        picture_marks!(md, dirs, pb.pictures)
    lines = render_markdown(md, pb.width)
    if contents
        titles = [strip(String(lines[i])) for i in heading_lines(lines)]
        if length(titles) >= 3
            segs = Any[("Contents ", :REPL_DocBrowser_dim)]
            for (k, t) in enumerate(titles)
                k > 1 && push!(segs, (" · ", :REPL_DocBrowser_dim))
                push!(segs, (t, nothing, AnchorTarget(k)))
            end
            addflow!(pb, "  ", segs)
            addline!(pb)
        end
    end
    # The blocks of code come out in the order of the Markdown's, which says how many lines each
    # has, so a blank line does not split one, and what language it is in.
    nodes = md isa Markdown.MD ? code_nodes!(Markdown.Code[], md) : Markdown.Code[]
    block = String[]
    lang = ""
    left = 0 # lines still to come of a block whose length is known
    for line in lines
        if left == 0 && !isempty(marks) && (m = match(PICTURE_MARK, String(line))) !== nothing
            add_picture!(pb, SubString(line, 1, ncodeunits(m[1])), marks[parse(Int, m[2])])
            continue
        end
        code = is_code_line(line)
        if left == 0 && code && !isempty(nodes)
            isempty(block) || (add_copy_mark!(pb, block, lang); empty!(block))
            node = popfirst!(nodes)
            left, lang = count(==('\n'), node.code) + 1, node.language
        end
        inblock = left > 0 || code
        if !inblock && !isempty(block)
            add_copy_mark!(pb, block, lang)
            empty!(block)
            lang = ""
        end
        if left > 0
            left -= 1
            # a blank line in the block is marked as code too, so that it is shaded with it
            code || isempty(line) || (line = AnnotatedString(String(line), [(region=1:ncodeunits(line), label=:face, value=:markdown_code)]))
        end
        # Code is indented further, which leaves room for its mark in the margin.
        push!(pb.lines, inblock ? concat("  ", untab(line)) : untab(line))
        find_spots!(pb.spots, length(pb.lines), pb.lines[end], ctx, refs, cat)
        inblock && push!(block, String(line))
    end
    isempty(block) || add_copy_mark!(pb, block, lang)
end

# An image to draw as a picture: its file, its width and height in pixels, and its text.
const PictureMark = Tuple{String,Int,Int,String}

# The word that holds the place of the `n`th picture while the Markdown is rendered, and what
# comes before it on its line, such as the bar of a note.
picture_mark(n::Int) = "￼$n"
const PICTURE_MARK = Regex("^(.*?)￼(\\d+)\\s*\$")

# The images that can be drawn as pictures, each of which is replaced by its mark. They are
# those that are paragraphs of their own, or end one, as an image on the line after its text
# does. Then the mark goes on a line of its own under the text.
function picture_marks!(md::Markdown.MD, dirs::Vector{String}, pics::PictureSupport)
    found = PictureMark[]
    walk_md(md) do x
        x isa Markdown.Paragraph || return
        i = findlast(y -> !(y isa AbstractString && isempty(strip(y))), x.content)
        i !== nothing && x.content[i] isa Markdown.Image || return
        img = x.content[i]::Markdown.Image
        text = x.content[1:i-1]
        alone = all(y -> y isa AbstractString && isempty(strip(y)), text)
        file = image_file(img.url, dirs)
        (file === nothing || picture_id(file) in pics.refused) && return
        size = png_size(file)
        if size === nothing
            png = read_image(file)
            if png === nothing
                format = image_format(file)
                format === nothing && return
                if format[2] && pics.images ∉ (:loaded, :failed)
                    # A box holds its place until DocBrowserImages can draw it.
                    pics.wanted[] = true
                    size = (0, 0)
                else
                    alone && (x.content = Any[isempty(img.alt) ? "($(format[1]) image)" : "($(format[1]) image: $(img.alt))"])
                    return
                end
            else
                size = (png[2], png[3])
            end
        end
        push!(found, (file, size[1], size[2], img.alt))
        mark = picture_mark(length(found))
        x.content = alone ? Any[mark] : Any[text..., Markdown.LineBreak(), mark]
    end
    return found
end

# A box where an image will be drawn, which says what draws it, with the image's text under it.
function add_holder!(pb::PageBuilder, prefix, file::String, alt::String)
    col = textwidth(String(prefix)) + 1
    name = image_format(file)[1]
    note = (pb.pictures::PictureSupport).images === :absent ? "add DocBrowserImages to draw it" : "loading DocBrowserImages…"
    # as wide as leaves the same space either side of the note
    inner = clamp(max(36 + isodd(textwidth(note)), textwidth(note) + 4), 1, max(1, pb.width - col - 3))
    border = :REPL_DocBrowser_border
    function line(text)
        text = first(text, inner)
        left = (inner - textwidth(text)) ÷ 2
        middle = " "^left * text * " "^(inner - textwidth(text) - left)
        return concat(prefix, styled("│", border), styled(middle, :REPL_DocBrowser_dim), styled("│", border))
    end
    top = length(pb.lines) + 1
    push!(pb.lines, concat(prefix, styled("╭" * "─"^inner * "╮", border)))
    push!(pb.lines, line(""))
    push!(pb.lines, line("$name image"))
    push!(pb.lines, line(note))
    push!(pb.lines, line(""))
    push!(pb.lines, concat(prefix, styled("╰" * "─"^inner * "╯", border)))
    push!(pb.holders, ImageHolder(top, col, length(pb.lines) - top + 1, inner + 2, name))
    isempty(alt) || push!(pb.lines, concat(prefix, styled(alt, :REPL_DocBrowser_dim)))
end

# Blank rows for a picture, with its text under it. They start as its mark's line did, so a
# picture in a note keeps the note's bar beside it.
function add_picture!(pb::PageBuilder, prefix, (file, w, h, alt)::PictureMark)
    w == 0 && return add_holder!(pb, prefix, file, alt)
    col = textwidth(String(prefix)) + 1
    pic = file_picture(file, w, h, pb.width - col - 1, (pb.pictures::PictureSupport).cell)
    push!(pb.images, PageImage(length(pb.lines) + 1, col, pic, file))
    for _ in 1:pic.rows
        push!(pb.lines, concat(prefix))
    end
    isempty(alt) || push!(pb.lines, concat(prefix, styled(alt, :REPL_DocBrowser_dim)))
end

# The blocks of code in `x`, in the order they are shown. Those that show without the face of
# code, being empty or styled text, are left out.
function code_nodes!(out::Vector{Markdown.Code}, @nospecialize(x))
    if x isa Markdown.Code
        isempty(x.code) || x.language == "styled" || push!(out, x)
    elseif x isa Markdown.MD || x isa Markdown.Admonition || x isa Markdown.BlockQuote
        for y in x.content::Vector{Any}
            code_nodes!(out, y)
        end
    elseif x isa Markdown.List
        for item in x.items
            item isa AbstractVector || continue
            for y in item
                code_nodes!(out, y)
            end
        end
    end
    return out
end

# Julia code, as an example at the prompt or not. Documentation that names no language is
# written in Julia, and so are Documenter's `@example` and `@repl` blocks.
is_julia_code(lang::AbstractString) =
    lang in ("", "julia", "julia-repl") || startswith(lang, "jldoctest") || startswith(lang, "@")

is_code_line(line::AnnotatedString) =
    any(a -> a.label === :face && (v = a.value; v === :markdown_code || v === :markdown_julia_prompt), annotations(line))

"""
    paste_text(lines) -> String

What to copy or paste for a rendered code block: the input of each `julia>` prompt in an
example, or else the whole block.
"""
function paste_text(lines::Vector{String})
    text = String[]
    prompt = false
    for l in lines
        t = String(chopprefix(l, "  "))
        push!(text, t)
        prompt |= startswith(t, "julia> ")
    end
    if prompt
        inputs = String[]
        continuing = false
        for l in text
            if startswith(l, "julia> ")
                push!(inputs, l[8:end])
                continuing = true
            elseif continuing && startswith(l, ' '^7)
                inputs[end] *= "\n" * l[8:end]
            else
                continuing = false
            end
        end
        return join(inputs, '\n')
    end
    out = IOBuffer()
    for (i, t) in enumerate(text)
        i > 1 && print(out, '\n')
        print(out, rstrip(t))
    end
    return String(take!(out))
end

# A place in the margin of the first line of a block of code that copies the code. Its ⧉ is
# drawn only while the pointer or the cursor is in the block.
function add_copy_mark!(pb::PageBuilder, block::Vector{String}, lang::AbstractString)
    code = paste_text(block)
    isempty(strip(code)) && return
    push!(pb.spots, Spot(length(pb.lines) - length(block) + 1, 1:1, CodeTarget(code, is_julia_code(lang))))
end

## Source locations ##

function source_target(d::DocStr)
    path = get(d.data, :path, nothing)
    line = get(d.data, :linenumber, 0)
    path isa AbstractString && !isempty(path) || return nothing
    return SourceTarget(source_path(path), line isa Int ? line : 0)
end

function source_path(path::AbstractString)
    path = Base.fixup_stdlib_path(String(path))
    if !isfile(path)
        found = Base.find_source_file(path)
        found === nothing || (path = found)
    end
    return path
end

function method_target(m::Method)
    file, line = Base.updated_methodloc(m)
    return SourceTarget(source_path(string(file)), Int(line))
end

function doc_sources(results::Vector{DocStr})
    sources = SourceTarget[]
    for d in results
        t = source_target(d)
        t === nothing || push!(sources, t)
    end
    return sources
end

const MAX_LISTED = 100

# The Markdown of each docstring. Packages add their own ways to format docstrings.
parse_docs(results::Vector{DocStr}) = Any[dynamic(REPL.parsedoc)(d) for d in results]

# The docstrings of a name, set apart: each after a line that says which module it is from when
# they come from several, as when a package adds a method to a function of Base, or else after
# a rule.
function labelled_docs(results::Vector{DocStr})
    docs = parse_docs(results)
    length(docs) > 1 || return docs
    mods = Union{Module,Nothing}[(m = get(d.data, :module, nothing); m isa Module ? m : nothing) for d in results]
    labels = length(unique(mods)) > 1
    out = Any[]
    for (i, (m, md)) in enumerate(zip(mods, docs))
        if labels && m isa Module
            push!(out, Markdown.MD(Any[Markdown.Paragraph(Any["From ", Markdown.Code(display_name(m)), ":"])]))
        elseif i > 1
            push!(out, Markdown.MD(Any[Markdown.HorizontalRule()]))
        end
        push!(out, md)
    end
    return out
end

"""
    add_methods!(pb, title, ms)

List methods `ms` by signature. Each links to its definition.
"""
function add_methods!(pb::PageBuilder, title::String, ms)
    isempty(ms) && return
    heading!(pb, string(title, " (", length(ms), ")"))
    for (i, m) in enumerate(ms)
        i > MAX_LISTED && break
        sig = String(first(split(sprint(show, m; context = :compact => true), " @ "; limit=2)))
        t = method_target(m)
        addline!(pb, "    ", (sig, nothing, t), ("  " * basename(source_label(t)), :REPL_DocBrowser_dim))
    end
    length(ms) > MAX_LISTED && addline!(pb, "    ", ("… and $(length(ms) - MAX_LISTED) more", :REPL_DocBrowser_dim))
end

function source_label(t::SourceTarget)
    path = Base.contractuser(t.file)
    return t.line > 0 ? string(path, ':', t.line) : path
end

function add_sources!(pb::PageBuilder, sources::Vector{SourceTarget})
    isempty(sources) && return
    heading!(pb, length(sources) == 1 ? "Source" : "Sources")
    for t in sources
        addline!(pb, "    ", (source_label(t), :REPL_DocBrowser_link, t))
    end
end

## Pages for names ##

const VIS_WORDS = (exported = "exported", public = "public", internal = "internal")

vis_face(vis::Symbol) = Symbol(:REPL_DocBrowser_, vis)

function kind_word(e::NameEntry)
    e.kind === :type || return String(e.kind)
    T = Base.unwrap_unionall(entry_value(e))
    T isa DataType || return "type"
    isabstracttype(T) && return "abstract type"
    isprimitivetype(T) && return "primitive type"
    return ismutabletype(T) ? "mutable struct" : "struct"
end

display_name(m::Module) = join(String[String(s) for s in fullname(m)], '.')

function display_name(e::NameEntry)
    is_module_entry(e) && return display_name(e.mod)
    e.mod === Main && return String(e.name)
    name = String(e.name)
    Base.isoperator(e.name) && (name = ":" * name)
    return string(display_name(e.mod), '.', name)
end

function type_target(@nospecialize(T))
    T = Base.unwrap_unionall(T)
    T isa DataType || return nothing
    m, s = parentmodule(T), nameof(T)
    visible_binding(m, s) || return nothing
    return NameTarget(m, s)
end

function add_type_info!(pb::PageBuilder, @nospecialize(T), flags::Set{Symbol})
    D = Base.unwrap_unionall(T)
    # Types such as `Tuple` and `NamedTuple` have no definite number of fields.
    nfields = D isa DataType && !isabstracttype(D) ? something(Base.datatype_fieldcount(D), 0) : 0
    if nfields > 0
        heading!(pb, "Fields")
        for (name, FT) in zip(fieldnames(D), fieldtypes(D))
            addline!(pb, "    ", String(name), ("::", :REPL_DocBrowser_dim), (string(FT), nothing, type_target(FT)))
        end
    end
    add_supertypes!(pb, T)
    if D isa DataType && isabstracttype(D)
        subs = @attempt dynamic(InteractiveUtils.subtypes)(T)::Vector{Any} Any[]
        if !isempty(subs)
            heading!(pb, "Subtypes ($(length(subs)))")
            segs = Any[]
            for S in Iterators.take(subs, MAX_LISTED)
                isempty(segs) || push!(segs, ("  ", nothing))
                push!(segs, (string(S), nothing, type_target(S)))
            end
            addflow!(pb, "    ", segs)
        end
    end
    add_methods!(pb, "Constructors", methods(T))
    if :methodswith in flags
        # hidden from inference, so it is compiled only when someone asks for it
        ms = (@attempt Base.inferencebarrier(InteractiveUtils.methodswith)(T; supertypes=false) Method[])::Vector{Method}
        add_methods!(pb, "Methods that take this type", ms)
        isempty(ms) && (heading!(pb, "Methods that take this type"); addline!(pb, "    ", ("none found", :REPL_DocBrowser_dim)))
    else
        addline!(pb)
        addline!(pb, "  ", ("▸ Find the methods that take this type", nothing, ToggleTarget(:methodswith)))
    end
end

function add_supertypes!(pb::PageBuilder, @nospecialize(T))
    T = Base.unwrap_unionall(T)
    T isa DataType && T !== Any || return
    segs = Any[]
    sts = InteractiveUtils.supertypes(T)
    for i in 2:length(sts)
        S = sts[i]
        i > 2 && push!(segs, (" <: ", :REPL_DocBrowser_dim))
        push!(segs, (string(nameof(S)), nothing, type_target(S)))
    end
    heading!(pb, "Supertypes")
    addflow!(pb, "    ", segs)
end

function entry_page(cat::Catalog, e::NameEntry, width::Int, flags::Set{Symbol}=Set{Symbol}())
    is_module_entry(e) && return module_page(cat, e.mod, width)
    pb = PageBuilder(width)
    addline!(pb)
    addline!(pb, "  ", (display_name(e), :REPL_DocBrowser_title))
    results = doc_results(Binding(e.mod, e.name))
    meta = Any["  ", (kind_word(e), kind_face(e.kind)), (" · ", :REPL_DocBrowser_dim),
               (getfield(VIS_WORDS, e.vis), vis_face(e.vis))]
    if e.owner !== e.mod
        push!(meta, (" · from ", :REPL_DocBrowser_dim), (display_name(e.owner), nothing, ModuleTarget(e.owner)))
    end
    n = length(results)
    push!(meta, (n == 0 ? " · undocumented" : n == 1 ? "" : " · $n docstrings", :REPL_DocBrowser_dim))
    e.deprecated && push!(meta, (" · deprecated", :warning))
    addline!(pb, meta...)
    if e.kind === :function
        nm = length(methods(entry_value(e)))
        addline!(pb, "  ", (string(nm, nm == 1 ? " method" : " methods"), :REPL_DocBrowser_dim))
    end
    rule!(pb)
    b = Binding(e.mod, e.name)
    md = isempty(results) ? dynamic(REPL.doc)(b) : dynamic(Base.Docs.catdoc)(labelled_docs(results)...)
    trimmed = false
    if md isa Markdown.MD
        brief, trimmed = REPL._trimdocs(md, true)
        trimmed && !(:extended in flags) && (md = brief)
    end
    add_markdown!(pb, md, e.owner, cat; contents=true)
    if trimmed
        addline!(pb)
        label = :extended in flags ? "▾ Hide the extended help" : "▸ Show the extended help"
        addline!(pb, "  ", (label, nothing, ToggleTarget(:extended)), ("  x", :REPL_DocBrowser_dim))
    end
    val = entry_value(e)
    if e.kind === :type
        add_type_info!(pb, val, flags)
    elseif e.kind in (:function, :macro) && val isa Function
        add_methods!(pb, "Methods", methods(val))
    end
    sources = doc_sources(results)
    add_sources!(pb, unique!(sources))
    addline!(pb)
    return Page(pb, isempty(sources) ? nothing : first(sources))
end

## Links to the web ##

# Turn a git remote into the web address of the repository, or `nothing` for local paths.
function web_url(url::AbstractString)
    url = strip(url)
    m = match(r"^git@([^:]+):(.+)$", url)
    m === nothing || (url = string("https://", m[1], "/", m[2]))
    url = replace(url, r"^(git://|ssh://git@)" => "https://")
    startswith(url, r"https?://") || return nothing
    # A remote can hold a user name and token, which must not be shown or opened.
    url = replace(url, r"^(https?://)[^/@]*@" => s"\1")
    return String(chopsuffix(chopsuffix(url, "/"), ".git"))
end

function git_remote(dir)
    dir === nothing && return nothing
    config = joinpath(dir, ".git", "config")
    isfile(config) || return nothing
    m = match(r"\[remote \"origin\"\][^\[]*?url\s*=\s*(\S+)"s, read(config, String))
    return m === nothing ? nothing : m[1]
end

# The entries of the active project's manifest for the packages called `name`. There can be
# several, with different UUIDs.
function manifest_entries(name::String)
    entries = Dict{String,Any}[]
    project = Base.active_project()
    project === nothing && return entries
    d = read_project(Base.project_file_manifest_path(project))
    d === nothing && return entries
    listed = get(get(d, "deps", d), name, nothing)
    listed isa AbstractVector || return entries
    for e in listed
        e isa Dict{String,Any} && push!(entries, e)
    end
    return entries
end

function manifest_repo(id::PkgId)
    for e in manifest_entries(id.name)
        get(e, "uuid", nothing) == string(id.uuid) || continue
        url = get(e, "repo-url", nothing)
        return url isa String ? url : nothing
    end
    return nothing
end

# Only registries unpacked into directories can be read here; compressed ones are skipped.
function registry_repo(id::PkgId)
    for depot in DEPOT_PATH
        regs = joinpath(depot, "registries")
        isdir(regs) || continue
        for name in readdir(regs)
            reg = joinpath(regs, name)
            d = read_project(joinpath(reg, "Registry.toml"))
            d === nothing && continue
            entry = get(get(d, "packages", Dict()), string(id.uuid), nothing)
            entry isa AbstractDict || continue
            path = get(entry, "path", "")
            path isa AbstractString || continue
            info = read_project(joinpath(reg, as_string(path), "Package.toml"))
            url = info === nothing ? nothing : get(info, "repo", nothing)
            url isa String && return url
        end
    end
    return nothing
end

"""
    repo_url(id, dir) -> Union{String, Nothing}

The web address of package `id`'s repository, if it can be found offline: from the git
remote of a developed package, from the manifest, or from an unpacked registry.
"""
function repo_url(id::PkgId, dir)
    id.uuid === nothing && return nothing
    for url in (git_remote(dir), manifest_repo(id), registry_repo(id))
        url === nothing && continue
        web = web_url(url)
        web === nothing || return web
    end
    return nothing
end

link_label(url::String) = replace(url, r"^https?://(www\.)?" => "")

const LICENCES = (r"MIT License|MIT \"Expat\"|Permission is hereby granted, free of charge" => "MIT",
                  r"Apache License" => "Apache-2.0", r"GNU LESSER GENERAL PUBLIC" => "LGPL",
                  r"GNU AFFERO" => "AGPL", r"GNU GENERAL PUBLIC LICENSE" => "GPL",
                  r"Mozilla Public License" => "MPL-2.0", r"Boost Software License" => "BSL-1.0",
                  r"ISC License" => "ISC", r"Unlicense|unencumbered software" => "Unlicense",
                  r"Redistribution and use in source and binary forms" => "BSD",
                  r"^COPYRIGHT AND PERMISSION NOTICE" => "curl")

"""
    licence(dir) -> Union{String, Nothing}

The names of the licences in directory `dir`, guessed from the start of each licence file.
"""
function licence(dir)
    (dir === nothing || !isdir(dir)) && return nothing
    found = String[]
    unknown = nothing
    for f in readdir(dir)
        path = joinpath(dir, f)
        isfile(path) || continue
        # BinaryBuilder names some licence files after their SPDX identifier, as in GPL-3.0+
        if occursin(r"^[A-Z][A-Za-z]*-\d[\d.]*\+?$", f)
            push!(found, f)
            continue
        end
        occursin(r"^(un)?licen[cs]e|^copying"i, f) || continue
        head = open(io -> join(Iterators.take(eachline(io), 30), ' '), path)
        spdx = match(r"SPDX-License-Identifier:\W*([A-Za-z0-9.+-]+)", head)
        name = spdx === nothing ? nothing : String(spdx[1])
        for (re, n) in LICENCES
            name === nothing || break
            occursin(re, head) && (name = n)
        end
        name === nothing ? (unknown === nothing && (unknown = f)) : push!(found, name)
    end
    isempty(found) || return join(unique!(found), ", ")
    return unknown === nothing ? nothing : "see $unknown"
end

# The licence files of the library a JLL package provides.
function jll_licence_dir(id::PkgId)
    lib = chopsuffix(id.name, "_jll")
    root = Base.root_module_exists(id) ? Base.root_module(id) : nothing
    if root !== nothing && isdefined(root, :artifact_dir)
        dir = joinpath(as_string(string(getglobal(root, :artifact_dir))), "share", "licenses", lib)
        isdir(dir) && return dir
    end
    return joinpath(dirname(Sys.BINDIR), "share", "licenses", lib)
end

"""
    julia_docs(path="", v=VERSION) -> String

The address of `path` in the manual for Julia version `v`.
"""
function julia_docs(path::AbstractString="", v::VersionNumber=VERSION)
    # `vX.Y` is the latest release of X.Y. `vX.Y-dev` is built from master, and then from the
    # release branch, so it covers every prerelease, including tags whose docs were not deployed.
    ver = "v$(v.major).$(v.minor)" * (isempty(v.prerelease) ? "" : "-dev")
    return "https://docs.julialang.org/en/$ver/$path"
end

const BADGE_PATTERNS = (
    r"\[!\[([^\]]*)\]\(([^)\s]+)[^)]*\)\]\(([^)\s]+)\)",   # [![alt](image)](url)
    r"^\s*\[([^\]]+)\]:\s*<?([^>\s]+)>?\s*$"m,             # [label]: url
    r"<a[^>]+href=\"([^\"]+)\"[^>]*>\s*<img([^>]+)>")       # <a href="url"><img ...>

"""
    docs_url(dir) -> Union{String, Nothing}

The address of a package's full documentation: the `url` in the `[docs]` section of its project
file, for its version, or else a link in its README, preferring the stable version over the
development one.
"""
function docs_url(dir)
    (dir === nothing || !isdir(dir)) && return nothing
    # The package's own word for it, in the `[docs]` section of its project file.
    d = package_project(dir)
    section = get(d, "docs", nothing)
    url = section isa AbstractDict ? get(section, "url", nothing) : nothing
    v = get(d, "version", nothing)
    url isa String && occursin(r"^https?://", url) &&
        return v isa String ? replace(url, "{version}" => v) : replace(url, "v{version}" => "stable")
    readme = find_readme(dir)
    readme === nothing && return nothing
    text = @attempt read(readme, String) return nothing
    found = nothing
    for (i, re) in enumerate(BADGE_PATTERNS), m in eachmatch(re, text)
        label, url = i == 1 ? (m[1] * " " * m[2], m[3]) : i == 2 ? (m[1], m[2]) : (m[2], m[1])
        url = String(url)
        occursin(r"^https?://", url) || continue
        # badge images, which may have a query string or no extension
        occursin(r"\.(svg|png)(\?|$)|img\.shields\.io|badgen\.net"i, url) && continue
        # badges for CI, coverage and registry pages
        occursin(r"/actions|codecov|coveralls|travis|appveyor|juliahub\.com/ui"i, url) && continue
        occursin(r"docs?\b|documentation"i, label) || continue
        occursin(r"stable"i, label * url) && return url
        found === nothing && (found = url)
    end
    found === nothing || return found
    # Without a badge, a plain link to documentation, as in Makie's "Read the docs [here](…)".
    # Julia's own manual is documentation of something else.
    for m in eachmatch(r"\[([^\]]*)\]\((https?://[^)\s]+)\)", text)
        label, url = m[1], String(m[2])
        occursin(r"^https?://[^/]*julialang\.org"i, url) && continue
        occursin(r"\bdocs?\b|documentation"i, label) || occursin(r"^https?://docs\."i, url) || continue
        occursin(r"stable"i, url) && return url
        found === nothing && (found = url)
    end
    return found
end

function add_links!(pb::PageBuilder, id::PkgId, dir, role::Symbol)
    segs = Any[]
    label = "licence "
    lic = if role === :julia
        "MIT"
    elseif isjll(id.name)
        # The wrapper's own licence matters less than that of the library it provides.
        label = chopsuffix(id.name, "_jll") * " licence "
        licence(jll_licence_dir(id))
    else
        # Standard libraries in Julia's repository are covered by Julia's licence.
        something(licence(dir), in_stdlib_dir(dir) ? "MIT" : nothing, Some(nothing))
    end
    lic === nothing || push!(segs, Any[(label, :REPL_DocBrowser_dim), (lic, nothing)])
    function link!(label, url, text=link_label(url))
        isempty(segs) || push!(segs, ("   ", nothing))
        push!(segs, Any[(label * " ", :REPL_DocBrowser_dim), (text, nothing, URLTarget(url))])
    end
    if role === :julia
        link!("repo", "https://github.com/JuliaLang/julia")
        link!("docs", julia_docs())
    else
        repo = repo_url(id, dir)
        if repo === nothing && isjll(id.name)
            # Every JLL is generated into the JuliaBinaryWrappers organisation.
            repo = "https://github.com/JuliaBinaryWrappers/$(id.name).jl"
        end
        repo === nothing || link!("repo", repo)
        docs = online_docs(id, dir)
        if docs !== nothing
            link!("docs", docs)
        elseif repo === nothing && !isjll(id.name)
            link!("search the web for", web_search(id.name).url, "$(id.name).jl")
        end
    end
    isempty(segs) || addflow!(pb, "  ", segs)
end

# Where a package's documentation is online, if that is known.
function online_docs(id::PkgId, dir)
    isjll(id.name) && return nothing
    url = docs_url(dir)
    url === nothing && is_stdlib(id) && return julia_docs("stdlib/$(id.name)/")
    return url
end

## Pages for modules ##

function role_line(cat::Catalog, m::Module)
    p = get(cat.bymod, m, nothing)
    dim = :REPL_DocBrowser_dim
    if p === nothing
        parent = parentmodule(m)
        return Any[("submodule of ", dim), (display_name(parent), nothing, ModuleTarget(parent))]
    end
    segs = Any[]
    if p.role === :project
        push!(segs, ("the active project", :REPL_DocBrowser_exported))
    elseif p.role === :direct
        push!(segs, (bound_in_main(m) && !in_project(p) ? "loaded in Main" : "direct dependency", :REPL_DocBrowser_exported))
    elseif p.role === :julia
        push!(segs, ("built into Julia", :REPL_DocBrowser_public))
    elseif p.role === :main
        push!(segs, ("your workspace module", :REPL_DocBrowser_public))
    elseif p.role === :extension
        push!(segs, ("package extension", dim))
        p.parent === nothing || push!(segs, (" of ", dim), (p.parent.name, nothing, package_target(cat, p.parent)))
    else
        push!(segs, ("indirect dependency", dim))
    end
    is_stdlib(p.id) && p.role in (:direct, :indirect) && push!(segs, (" · standard library", dim))
    if !isempty(p.via) && p.role === :indirect
        push!(segs, (" · loaded by ", dim))
        for (i, id) in enumerate(p.via)
            i > 1 && push!(segs, (" → ", dim))
            push!(segs, (id.name, nothing, package_target(cat, id)))
        end
    end
    return segs
end

function in_project(p::PkgEntry)
    _, direct = project_info()
    return p.id.uuid !== nothing && p.id.uuid in direct
end

function package_target(cat::Catalog, id::PkgId)
    for p in cat.pkgs
        p.id == id && return ModuleTarget(p.mod)
    end
    return nothing
end

# A name alone can be that of several loaded packages. It is then the one that the project
# depends on, which is the one that `import` would load.
function package_target(cat::Catalog, name::AbstractString)
    found = nothing
    for p in cat.pkgs
        p.id.name == name || continue
        p.role in (:project, :direct) && return ModuleTarget(p.mod)
        found === nothing && (found = p)
    end
    return found === nothing ? nothing : ModuleTarget(found.mod)
end

function count_segments(counts)
    segs = Any[]
    for vis in (:exported, :public, :internal)
        isempty(segs) || push!(segs, (" · ", :REPL_DocBrowser_dim))
        push!(segs, (string(counts[vis], ' ', getfield(VIS_WORDS, vis)), vis_face(vis)))
    end
    return segs
end

function module_page(cat::Catalog, m::Module, width::Int)
    pb = PageBuilder(width)
    p = get(cat.bymod, m, nothing)
    addline!(pb)
    version = p === nothing || p.version === nothing ? "" : string("  v", p.version)
    addline!(pb, "  ", (display_name(m), :REPL_DocBrowser_title), (version, :REPL_DocBrowser_dim))
    addflow!(pb, "  ", role_line(cat, m))
    entries = module_entries(cat, m)
    addline!(pb, "  ", count_segments(count_visibility(entries))...)
    # An extension's directory, README and licence are those of the package it extends.
    ext = p !== nothing && p.role === :extension
    dir = p === nothing ? nothing : ext ? pathof(m) : pkgdir(m)
    dir === nothing || addline!(pb, "  ", (Base.contractuser(dir), :REPL_DocBrowser_dim))
    p === nothing || ext || p.role === :main || add_links!(pb, p.id, dir, p.role)
    docs = package_docs(cat, m)
    manual = isempty(docs.pages) ? (p === nothing || ext ? nothing : package_manual(m)) : docs.pages[1].path
    if manual !== nothing
        headings = scan_headings(manual; limit=1)
        add_manual_line!(pb, isempty(headings) ? "index.md" : headings[1].text, manual, length(docs.pages))
    elseif p !== nothing && !ext && p.role in (:project, :direct, :indirect)
        add_fetch_line!(pb)
    end
    p === nothing || gap_notice!(pb, docs, online_docs(p.id, dir))
    rule!(pb)
    results = doc_results(module_binding(m))
    if !isempty(results)
        md = dynamic(Base.Docs.catdoc)(parse_docs(results)...)
    elseif ext
        md = Markdown.parse("No docstring found for `$(display_name(m))`.")
    else
        readme = REPL.find_readme(m)
        if readme === nothing
            md = p !== nothing && isjll(p.id.name) ? jll_markdown(m, p) :
                Markdown.parse("No docstring or README found for `$(display_name(m))`.")
        else
            addline!(pb, "  ", ("No module docstring; showing $(basename(readme)).", :REPL_DocBrowser_dim))
            addline!(pb)
            md = readme_markdown(readme)
        end
    end
    add_markdown!(pb, md, m, cat; contents=true)
    submods = Any[]
    for e in entries
        e.kind === :module && is_submodule(m, entry_value(e)) || continue
        isempty(submods) || push!(submods, ("  ", nothing))
        push!(submods, (String(e.name), nothing, ModuleTarget(entry_value(e))))
    end
    if !isempty(submods)
        heading!(pb, "Submodules")
        addflow!(pb, "    ", submods)
    end
    if p !== nothing && !(p.role in (:julia, :main))
        add_package_links!(pb, cat, "Loaded dependencies", loaded_deps(cat, p))
        add_package_links!(pb, cat, "Used by", dependents(cat, p))
    end
    sources = doc_sources(results)
    if isempty(sources)
        path = pathof(m)
        path === nothing || !isfile(path) || push!(sources, SourceTarget(path, 1))
    end
    add_sources!(pb, unique!(sources))
    addline!(pb)
    return Page(pb, isempty(sources) ? nothing : first(sources))
end

# Markdown has no HTML blocks before Julia 1.14. Checking for the name as the code runs would
# make the code depend on that name, which loading other packages can invalidate.
const HTML_BLOCK = isdefined(Markdown, :HTMLBlock) ? getglobal(Markdown, :HTMLBlock) : Union{}

is_badge(x) = x isa Markdown.Image || x isa Markdown.LineBreak ||
    (x isa AbstractString && isempty(strip(x))) ||
    (x isa Markdown.Link && dynamic(all)(is_badge, x.text)::Bool)

"""
    strip_badges!(md) -> md

Remove the HTML blocks and the paragraphs made only of images from a README. They are
badges and logos, which show up as clutter in a terminal.
"""
function strip_badges!(md::Markdown.MD)
    filter!(md.content) do x
        x isa HTML_BLOCK && return false
        # before Julia 1.14 an HTML block is read as a paragraph of its text
        x isa Markdown.Paragraph && length(x.content) == 1 && x.content[1] isa AbstractString &&
            occursin(r"\A\s*<[a-zA-Z/!].*>\s*\z"s, x.content[1]) && return false
        x isa Markdown.Paragraph && !isempty(x.content) && dynamic(all)(is_badge, x.content)::Bool && return false
        return true
    end
    return md
end

"""
    jll_markdown(m, p) -> Markdown.MD

A page for a JLL package, which has no docstring or README of its own: what it wraps,
and the libraries and executables it provides.
"""
function jll_markdown(m::Module, p::PkgEntry)
    name = p.id.name
    v = p.version
    version = v === nothing ? "" : " $(VersionNumber(v.major, v.minor, v.patch))"
    io = IOBuffer()
    println(io, "`$name` is a binary wrapper. It provides prebuilt binaries of ",
            chopsuffix(name, "_jll"), version, ", made with ",
            "[BinaryBuilder](https://github.com/JuliaPackaging/BinaryBuilder.jl), for Julia code to use.\n")
    available = !isdefined(m, :is_available) || @attempt(Base.invokelatest(getglobal(m, :is_available))::Bool, true)
    available || println(io, "!!! warning\n    These binaries are not available on this platform.\n")
    libs, exes = String[], String[]
    for n in names(m)
        n === nameof(m) && continue
        val = getglobal(m, n)
        pathname = Symbol(n, "_path")
        path = isdefined(m, pathname) ? getglobal(m, pathname) : nothing
        where = path isa AbstractString && !isempty(path) ? ", at `$(Base.contractuser(as_string(path)))`" : ""
        if val isa Function
            push!(exes, "  * `$n()`: a command that runs `$n`$where.")
        else
            push!(libs, "  * `$n`: the library$where.")
        end
    end
    isempty(libs) || println(io, "# Libraries\n\nPass these to `ccall` or `@ccall`.\n\n", join(libs, '\n'), '\n')
    isempty(exes) || println(io, "# Executables\n\nCall these to get a `Cmd` to `run`.\n\n", join(exes, '\n'), '\n')
    return Markdown.parse(String(take!(io)))
end

function loaded_deps(cat::Catalog, p::PkgEntry)
    uuids = Set(package_deps(p.mod))
    return PkgEntry[q for q in cat.pkgs if q.id.uuid !== nothing && q.id.uuid in uuids]
end

function dependents(cat::Catalog, p::PkgEntry)
    p.id.uuid === nothing && return PkgEntry[]
    return PkgEntry[q for q in cat.pkgs if q.id.uuid !== nothing && p.id.uuid in package_deps(q.mod)]
end

function add_package_links!(pb::PageBuilder, cat::Catalog, title::String, pkgs::Vector{PkgEntry})
    isempty(pkgs) && return
    heading!(pb, string(title, " (", length(pkgs), ")"))
    segs = Any[]
    for q in pkgs
        isempty(segs) || push!(segs, ("  ", nothing))
        push!(segs, (q.id.name, nothing, ModuleTarget(q.mod)))
    end
    addflow!(pb, "    ", segs)
end

## Pages for sidebar sections ##

const SECTION_TITLES = (docs = "Julia", code = "Packages", project = "Project",
                        direct = "Dependencies", julia = "Core and Base", manual = "Manual",
                        basedocs = "Base", stdlibdocs = "Standard library",
                        indirect = "Indirect dependencies",
                        extension = "Extensions", devdocs = "Developer documentation")

const SECTION_BLURBS = (
    project = "The package of the active project.",
    direct = "Packages that the active project depends on, and packages loaded into `Main` with `using` or `import`.",
    julia = "The docstrings of `Core` and `Base`, which are always loaded.",
    indirect = "Packages that were loaded because one of your packages needs them, or that Julia loaded for itself. Standard libraries with a manual are in Julia's Standard library instead.",
    extension = "Package extensions: code that a package loads once some other package is loaded too.",
    docs = "Julia's manual, written as a guide: how the language works, the functions of `Base` by topic, the standard libraries, and how Julia works inside.",
    code = "The packages that are loaded now: their manuals, where their source has one, and their docstrings, name by name.",
    manual = "The Julia manual: how the language works and how to use it.",
    basedocs = "The functions, types and macros of `Base`, grouped by topic, and the docstrings of `Core` and `Base`, name by name.",
    stdlibdocs = "The manual pages of the standard libraries. A page lists the names of its library, which become links once the library is loaded.",
    devdocs = "How Julia works inside, and how to build it and contribute to it.",
)

function section_page(cat::Catalog, role::Symbol, width::Int)
    pb = PageBuilder(width)
    addline!(pb)
    addline!(pb, "  ", (getfield(SECTION_TITLES, role), :REPL_DocBrowser_title))
    rule!(pb)
    add_markdown!(pb, Markdown.parse(getfield(SECTION_BLURBS, role)), Base, cat)
    status = role === :manual && !any(p -> p.role === :manual, cat.manual) ? manual_status() : :none
    if status === :downloading
        addtext!(pb, "  ", "Downloading the manual from GitHub. Its pages are listed here once it is done.",
                 :REPL_DocBrowser_dim)
    elseif status === :failed
        addtext!(pb, "  ", "The manual could not be downloaded: $(MANUAL_ERROR[])")
        addline!(pb)
        addline!(pb, "  ", ("▸ Try again", nothing, ToggleTarget(:download)))
    end
    if role in (:direct, :project)
        proj = Base.active_project()
        proj === nothing || addline!(pb, "  ", ("Active project: " * Base.contractuser(proj), :REPL_DocBrowser_dim))
    end
    pkgs = PkgEntry[p for p in cat.pkgs if p.role === (role === :basedocs ? :julia : role)]
    addline!(pb)
    if role === :docs || role === :code
        for r in getfield(BLOCKS, role)
            n = count(p -> package_section(p) === r, cat.pkgs) + count(p -> p.role === r, cat.manual)
            n == 0 && continue
            addline!(pb, "    ", (getfield(SECTION_TITLES, r), nothing, SectionTarget(r)), ("  $n", :REPL_DocBrowser_dim))
        end
    end
    group = ""
    # Pkg's manual is listed among the standard libraries, in its place.
    pkg = role === :stdlibdocs && any(p -> p.role === :pkgdocs, cat.manual)
    for p in cat.manual
        p.role === role || continue
        if pkg && lowercase(p.title) > "pkg"
            pkg_line!(pb, cat)
            pkg = false
        end
        if p.group != group
            group = p.group
            heading!(pb, group)
        end
        addline!(pb, "    ", (p.title, nothing, ManualTarget(p.path, "")))
    end
    pkg && pkg_line!(pb, cat)
    for p in pkgs
        version = p.version === nothing ? "" : string("  v", p.version)
        via = isempty(p.via) ? "" : string("  via ", join(String[id.name for id in p.via], " → "))
        addline!(pb, "    ", (p.id.name, nothing, ModuleTarget(p.mod)), (version * via, :REPL_DocBrowser_dim))
    end
    if role in (:project, :direct)
        self = project_id()
        for id in cat.unloaded
            (id == self) == (role === :project) || continue
            addline!(pb, "    ", (id.name, nothing, LoadTarget(id)), ("  not loaded", :REPL_DocBrowser_dim))
        end
    end
    addline!(pb)
    return Page(pb)
end

# Where a package's manual starts, and how many pages it has.
add_manual_line!(pb::PageBuilder, title::String, path::String, n::Int) =
    addline!(pb, "  ", ("manual ", :REPL_DocBrowser_dim), (title, nothing, ManualTarget(path, "")),
             (n > 1 ? "  $n pages, listed with the names" : "", :REPL_DocBrowser_dim))

function pkg_line!(pb::PageBuilder, cat::Catalog)
    i = findfirst(p -> p.role === :pkgdocs, cat.manual)
    addline!(pb, "    ", ("Pkg", nothing, ManualTarget(cat.manual[i].path, "")))
end

function unloaded_page(cat::Catalog, id::PkgId, width::Int, then::String="")
    pb = PageBuilder(width)
    stdlib = is_stdlib(id)
    self = id == project_id()
    dir = unloaded_dir(id)
    addline!(pb)
    title = isempty(then) ? id.name : startswith(then, id.name * ".") ? then : "$(id.name).$then"
    addline!(pb, "  ", (title, :REPL_DocBrowser_title))
    # A package picked by its UUID can be one that only another package depends on.
    direct = stdlib || self || id in cat.unloaded
    addline!(pb, "  ", (stdlib ? "standard library · not loaded" : self ? "the active project · not loaded" :
                         direct ? "direct dependency · not loaded" : "indirect dependency · not loaded",
                         :REPL_DocBrowser_dim))
    dir === nothing || addline!(pb, "  ", (Base.contractuser(dir), :REPL_DocBrowser_dim))
    add_links!(pb, id, dir, stdlib ? :stdlib : :direct)
    # Its manual, which its source has, can be read before it is loaded.
    pages = unloaded_docs(cat, id).pages
    if isempty(then) && !isempty(pages)
        add_manual_line!(pb, pages[1].title, pages[1].path, length(pages))
    elseif isempty(then) && !stdlib
        add_fetch_line!(pb)
    end
    rule!(pb)
    what = isempty(then) ? "its docstrings are" : "the docstring of $then is"
    whose = stdlib ? "$(id.name) is a standard library" : self ? "$(id.name) is the active project" :
        direct ? "The active project depends on $(id.name)" : "A package of the active project depends on $(id.name)"
    how = direct ? "import $(id.name) in Main" : "its code"
    addtext!(pb, "  ", "$whose, but it has not been loaded yet, so $what not available. Loading it runs $how.")
    addline!(pb)
    addline!(pb, "  ", (" Load $(id.name) ", :REPL_DocBrowser_link_active, LoadTarget(id, then)),
             ("  or press ⏎", :REPL_DocBrowser_dim))
    addline!(pb)
    readme = isempty(then) && dir !== nothing ? find_readme(dir) : nothing
    if readme !== nothing
        rule!(pb)
        addline!(pb, "  ", ("Its $(basename(readme)):", :REPL_DocBrowser_dim))
        addline!(pb)
        add_markdown!(pb, readme_markdown(readme), Main, cat)
    end
    return Page(pb)
end

# A README, without its badges, and without the definitions of reference links (`[x]: url`),
# which the Markdown parser keeps as text, as it does badges that use them.
function readme_markdown(path::String)
    text = @attempt read(path, String) return Markdown.parse("Could not read `$path`.")
    text = replace(text, r"^ {0,3}\[[^\]\n]+\]:[ \t]*\S+.*$"m => "",
                   # badges written with reference links, which are not read as images
                   r"\[!\[[^\]\n]*\]\[[^\]\n]*\]\]\[[^\]\n]*\]" => "", r"!\[[^\]\n]*\]\[[^\]\n]*\]" => "")
    return strip_badges!(Markdown.parse(text))
end

# The README in a package's directory, if it has one.
function find_readme(dir::String)
    files = readdir(dir)
    i = findfirst(f -> occursin(r"^readme(\.md)?$"i, f), files)
    return i === nothing ? nothing : joinpath(dir, files[i])
end
