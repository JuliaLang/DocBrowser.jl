using DocBrowserImages, FileIO, Test

# The width and height that a PNG file's header gives.
png_size(png) = Tuple(Int(ntoh(reinterpret(UInt32, png[i:i+3])[1])) for i in (17, 21))

@testset "DocBrowserImages" begin
    mktempdir() do dir
        svg = joinpath(dir, "shape.svg")
        write(svg, """<svg xmlns="http://www.w3.org/2000/svg" width="120" height="80"><polygon points="10,70 60,10 110,70"/></svg>""")
        # Each image is written as PNG, of the size that is returned with it.
        png, w, h = DocBrowserImages.read_png(svg)
        @test png[1:8] == b"\x89PNG\r\n\x1a\n" && png_size(png) == (w, h) == (120, 80)
        out = joinpath(dir, "out.png")
        write(out, png)
        jpg = joinpath(dir, "photo.jpg")
        FileIO.save(jpg, FileIO.load(out))
        png, w, h = DocBrowserImages.read_png(jpg)
        @test png_size(png) == (w, h) == (120, 80)
        bad = joinpath(dir, "bad.svg")
        write(bad, "not an image")
        @test_throws Exception DocBrowserImages.read_png(bad)
    end
end
