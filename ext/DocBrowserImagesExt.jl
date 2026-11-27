module DocBrowserImagesExt

import DocBrowser: png_image
import DocBrowserImages

png_image(file::String) = DocBrowserImages.read_png(file)

end
