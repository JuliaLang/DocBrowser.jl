"""
    DocBrowserImages

Lets DocBrowser draw the JPEG, TIFF, SVG and other images in manuals that the terminal cannot
read itself, by writing them as PNG. Loading it is all it takes, and the browser loads it by
itself when it is installed.
"""
module DocBrowserImages

import Cairo, FileIO, ImageIO, Rsvg

const MAX_RASTER = 1024

"""
    read_png(file) -> (png, width, height)

The image in `file` as the contents of a PNG file, with its width and height in pixels.
"""
function read_png(file::String)
    lowercase(splitext(file)[2]) == ".svg" && return svg_png(file)
    img = FileIO.load(file)
    ndims(img) == 3 && (img = img[:, :, 1]) # the first page of a TIFF file with several
    # A photo as PNG can be many times its size as JPEG. The terminal shows no more than
    # about a thousand pixels across, so a large image keeps every `step`th pixel.
    step = cld(maximum(size(img)), MAX_RASTER)
    step > 1 && (img = img[1:step:end, 1:step:end])
    io = IOBuffer()
    FileIO.save(FileIO.Stream{FileIO.format"PNG"}(io), img)
    return take!(io), size(img, 2), size(img, 1)
end

# An SVG image is drawn at its own size, or smaller if that is large.
function svg_png(file::String)
    handle = Rsvg.handle_new_from_file(file)
    handle.ptr == C_NULL && error("cannot read $file")
    dims = Rsvg.handle_get_dimensions(handle)
    scale = min(1.0, 2048 / max(dims.width, dims.height))
    w, h = max(1, round(Int, scale * dims.width)), max(1, round(Int, scale * dims.height))
    surface = Cairo.CairoImageSurface(w, h, Cairo.FORMAT_ARGB32)
    cr = Cairo.CairoContext(surface)
    Cairo.scale(cr, scale, scale)
    Rsvg.handle_render_cairo(cr, handle)
    io = IOBuffer()
    Cairo.write_to_png(surface, io)
    return take!(io), w, h
end

end
