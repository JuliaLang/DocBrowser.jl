# Pictures, for the terminals that draw them with the kitty graphics protocol:
# https://sw.kovidgoyal.net/kitty/graphics-protocol/

images_enabled() = lowercase(get(ENV, "JULIA_DOCBROWSER_IMAGES", "yes")) ∉ ("no", "false", "0")

# The number the browser's question carries, which the terminal's answer repeats.
const GRAPHICS_QUERY_ID = 31

# Asks for the size of a cell, whether the terminal draws pictures, and for its device
# attributes. A terminal that draws no pictures is silent about them, but every terminal
# answers the last, which is how the browser knows that no other answer is coming.
const GRAPHICS_QUERY = "\e[16t\e_Gi=$GRAPHICS_QUERY_ID,s=1,v=1,a=q,t=d,f=24;AAAA\e\\\e[c"

# How long the first frame waits for those answers, in seconds, and how long a picture that
# was sent is expected before the browser draws text in its place.
const SETTLE_WAIT = 0.3
const PICTURE_WAIT = 2.0

# A picture of `cols` by `rows` cells, for cells of `cell`'s height and width, so that the
# terminal does not stretch it. Some terminals give the size of a cell in points, which are
# two pixels on a dense screen, so a picture has twice the pixels, within limits that keep
# it sharp and quick to send.
function Picture(id::Int, cols::Int, rows::Int, cell::Tuple{Int,Int})
    height, width = cell
    pixels = clamp(2 * width, 14, 20)
    return Picture(id, cols, rows, cols * pixels, rows * round(Int, pixels * height / width))
end

# The Julia logo, on the start page and small in the header. The numbers only have to differ
# from those of other programs' pictures in the same terminal.
logo_picture(cell) = Picture(27501, 9, 4, cell)
mark_picture(cell) = Picture(27502, 3, 1, cell)

"""
    logo_pixels(pic) -> Vector{UInt8}

The Julia logo as the pixels of `pic`, four bytes each: red, green, blue, and how opaque.
Around the dots it is clear, so the terminal's background shows.
"""
function logo_pixels(pic::Picture)
    w, h = pic.width, pic.height
    # The logo is 4 radii tall and 4.31 wide, with the dots' centres 2.31 radii apart.
    r = min(h / 4, w / 4.31)
    dots = ((LOGO_COLOURS.green, w / 2, h / 2 - r), (LOGO_COLOURS.red, w / 2 - 1.155r, h / 2 + r),
            (LOGO_COLOURS.purple, w / 2 + 1.155r, h / 2 + r))
    pixels = zeros(UInt8, 4 * w * h)
    for (colour, cx, cy) in dots
        for y in max(0, floor(Int, cy - r)):min(h - 1, ceil(Int, cy + r)), x in max(0, floor(Int, cx - r)):min(w - 1, ceil(Int, cx + r))
            # A pixel on the edge is as opaque as it is inside the dot, which smooths the edge.
            inside = clamp(r - hypot(x + 0.5 - cx, y + 0.5 - cy) + 0.5, 0.0, 1.0)
            inside == 0 && continue
            i = 4 * (y * w + x)
            pixels[i+1], pixels[i+2], pixels[i+3] = (colour >> 16) % UInt8, (colour >> 8) % UInt8, colour % UInt8
            pixels[i+4] = round(UInt8, 255 * inside)
        end
    end
    return pixels
end

## Pictures from files ##

# Larger files take too long to send, and the terminal shrinks them to fit anyway.
const MAX_PICTURE_BYTES = 4 * 1024 * 1024
# A picture is no taller than this many rows, so that a tall one does not fill the pane.
const MAX_PICTURE_ROWS = 30

# The file that an image's address names, in the first of `dirs` that has it. An address on
# the web names no file.
function image_file(url::AbstractString, dirs::Vector{String})
    occursin(r"^[a-z][a-z0-9+.-]*:"i, url) && return nothing
    rel = replace(url, r"[?#].*"s => "")
    isempty(rel) && return nothing
    for dir in dirs
        file = normpath(dir, rel)
        isfile(file) && return file
    end
    return nothing
end

"""
    png_size(file) -> Union{Nothing,Tuple{Int,Int}}

The width and height in pixels of the PNG image in `file`, or `nothing` if it is not one or
is too large to send. The terminal reads PNG itself, so other formats are left out.
"""
function png_size(file::String)
    head = @attempt open(io -> filesize(io) <= MAX_PICTURE_BYTES ? read(io, 24) : UInt8[], file) return nothing
    length(head) == 24 && head[1:8] == b"\x89PNG\r\n\x1a\n" && head[13:16] == b"IHDR" || return nothing
    w, h = (Int(ntoh(reinterpret(UInt32, head[i:i+3])[1])) for i in (17, 21))
    return w > 0 && h > 0 ? (w, h) : nothing
end

# The number a file's picture is kept under. It is above those of the logos.
picture_id(file::String) = 0x01000000 + Int(hash(file) % 0x7effffff)

# A picture of a `w` by `h` image, as wide as it is in pixels, if that is no more than
# `maxcols` cells, and as tall as keeps its shape.
function file_picture(file::String, w::Int, h::Int, maxcols::Int, (ch, cw)::Tuple{Int,Int})
    cols = clamp(round(Int, w / cw), 1, max(1, maxcols))
    rows = max(1, round(Int, cols * cw * h / (w * ch)))
    if rows > MAX_PICTURE_ROWS
        rows = MAX_PICTURE_ROWS
        cols = max(1, round(Int, rows * ch * w / (h * cw)))
    end
    return Picture(picture_id(file), cols, rows, w, h)
end

# Gives the terminal the pixels of `pic` to keep, without drawing them, four bytes each, or
# with `png` the contents of a PNG file. They go in pieces of at most 4096 bytes, and the
# terminal answers once it has them all.
function send_picture(io::IO, pic::Picture, pixels::Vector{UInt8}; png::Bool=false)
    data = base64encode(pixels)
    n = ncodeunits(data)
    for i in 1:4096:n
        i == 1 && png && print(io, "\e_Ga=t,f=100,i=", pic.id, ",")
        i == 1 && !png && print(io, "\e_Ga=t,f=32,i=", pic.id, ",s=", pic.width, ",v=", pic.height, ",")
        i == 1 || print(io, "\e_G")
        print(io, "m=", i + 4096 > n ? 0 : 1, ";", SubString(data, i, min(i + 4095, n)), "\e\\")
    end
end

"""
    Placement

Where a picture is on the screen: `rows` rows of it, from the cell at `row` and `col`, after
the `skip` rows of it that are scrolled out of sight.
"""
struct Placement
    picture::Picture
    row::Int
    col::Int
    skip::Int
    rows::Int
end

# Draws placement number `n`. The terminal does not move the cursor (`C=1`), and answers only
# if it fails (`q=1`).
function show_placement(io::IO, n::Int, p::Placement)
    h, rows = p.picture.height, p.picture.rows
    y = p.skip * h ÷ rows
    print(io, "\e[", p.row, ";", p.col, "H\e_Ga=p,q=1,C=1,i=", p.picture.id, ",p=", n, ",c=", p.picture.cols,
          ",r=", p.rows, ",y=", y, ",h=", (p.skip + p.rows) * h ÷ rows - y, "\e\\")
end

hide_placement(io::IO, n::Int, p::Placement) = print(io, "\e_Ga=d,q=2,d=i,i=", p.picture.id, ",p=", n, "\e\\")

# Takes the picture off the screen and out of the terminal's memory.
forget_picture(io::IO, pic::Picture) = print(io, "\e_Ga=d,q=2,d=I,i=", pic.id, "\e\\")
