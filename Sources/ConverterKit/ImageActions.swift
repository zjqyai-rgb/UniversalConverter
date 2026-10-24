import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import Vision

// MARK: - ImageIO helpers

public enum ImageKit {
    public static let writableTypes = Set((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? [])

    public static func load(_ url: URL) throws -> CGImage {
        if let src = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(src) > 0 {
            let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
            let w = props?[kCGImagePropertyPixelWidth] as? Int ?? 0
            let h = props?[kCGImagePropertyPixelHeight] as? Int ?? 0
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: max(w, h, 1),
            ]
            if let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) { return img }
            if let img = CGImageSourceCreateImageAtIndex(src, 0, nil) { return img }
        }
        // SVG and other formats NSImage understands.
        if let ns = NSImage(contentsOf: url) {
            var size = ns.size
            if size.width < 1 || size.height < 1 { size = CGSize(width: 1024, height: 1024) }
            if url.ext == "svg" { // render vectors at a useful resolution
                let scale = max(1, 2048 / max(size.width, size.height))
                size = CGSize(width: size.width * scale, height: size.height * scale)
            }
            let img = draw(width: Int(size.width), height: Int(size.height)) { ctx in
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
                ns.draw(in: CGRect(origin: .zero, size: size))
                NSGraphicsContext.restoreGraphicsState()
            }
            if let img { return img }
        }
        throw ConvertError.unreadable(url)
    }

    public static func draw(width: Int, height: Int, opaque: Bool = false, _ body: (CGContext) -> Void) -> CGImage? {
        guard width > 0, height > 0,
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: opaque ? CGImageAlphaInfo.noneSkipLast.rawValue : CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.interpolationQuality = .high
        body(ctx)
        return ctx.makeImage()
    }

    public static func flatten(_ image: CGImage, background: CGColor = .white) -> CGImage {
        draw(width: image.width, height: image.height, opaque: true) { ctx in
            ctx.setFillColor(background)
            ctx.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        } ?? image
    }

    public static func resize(_ image: CGImage, width: Int, height: Int) -> CGImage {
        draw(width: max(width, 1), height: max(height, 1)) { ctx in
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        } ?? image
    }

    public static func fit(_ image: CGImage, maxSide: Int) -> CGImage {
        let side = max(image.width, image.height)
        guard side > maxSide else { return image }
        let s = Double(maxSide) / Double(side)
        return resize(image, width: Int(Double(image.width) * s), height: Int(Double(image.height) * s))
    }

    /// Centers the image on a transparent square canvas.
    public static func squareCanvas(_ image: CGImage, side: Int) -> CGImage {
        let s = Double(side) / Double(max(image.width, image.height))
        let w = Double(image.width) * s, h = Double(image.height) * s
        return draw(width: side, height: side) { ctx in
            ctx.draw(image, in: CGRect(x: (Double(side) - w) / 2, y: (Double(side) - h) / 2, width: w, height: h))
        } ?? image
    }

    public static func write(_ image: CGImage, to url: URL, type: String, quality: Double = 0.9) throws {
        var img = image
        if ["public.jpeg", "com.microsoft.bmp", "public.jpeg-2000", "public.pbm"].contains(type) { img = flatten(image) }
        if type == "com.microsoft.ico" { img = squareCanvas(fit(image, maxSide: 256), side: min(256, max(image.width, image.height))) }
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil) else {
            throw ConvertError.failed("This Mac can't write \(url.pathExtension.uppercased()) images.")
        }
        let props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(dest, img, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ConvertError.failed("Couldn't write \(url.lastPathComponent).") }
    }

    /// Writes using the type matching the extension, falling back to PNG.
    public static func writeMatching(_ image: CGImage, source: URL, ctx: ActionContext, suffix: String) throws -> URL {
        var ext = source.ext
        var type = UTType(filenameExtension: ext)?.identifier ?? "public.png"
        if !writableTypes.contains(type) { ext = "png"; type = "public.png" }
        let out = ctx.destination(for: source, ext: ext, suffix: suffix)
        try write(image, to: out, type: type, quality: ctx.imageQuality)
        return out
    }

    public static func writeGIF(_ frames: [CGImage], delay: Double, to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, frames.count, nil) else {
            throw ConvertError.failed("Couldn't create GIF.")
        }
        let fileProps = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary
        let frameProps = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay, kCGImagePropertyGIFUnclampedDelayTime: delay]] as CFDictionary
        CGImageDestinationSetProperties(dest, fileProps)
        for f in frames { CGImageDestinationAddImage(dest, f, frameProps) }
        guard CGImageDestinationFinalize(dest) else { throw ConvertError.failed("Couldn't write GIF.") }
    }

    static let ciContext = CIContext()

    static func filter(_ image: CGImage, _ make: (CIImage) -> CIImage?) throws -> CGImage {
        let input = CIImage(cgImage: image)
        guard let out = make(input), let cg = ciContext.createCGImage(out, from: input.extent) else {
            throw ConvertError.failed("Image filter failed.")
        }
        return cg
    }

    static func pdfData(for images: [CGImage]) -> Data {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: nil, nil) else { return Data() }
        for img in images {
            var box = CGRect(x: 0, y: 0, width: img.width, height: img.height)
            ctx.beginPage(mediaBox: &box)
            ctx.draw(img, in: box)
            ctx.endPage()
        }
        ctx.closePDF()
        return data as Data
    }
}

// MARK: - Actions

enum ImageActions {
    static let inputs: Set<FileKind> = [.image, .svg]

    struct Format { let title, ext, uti, symbol: String; var aliases: Set<String> = [] }

    static let formats: [Format] = [
        Format(title: "PNG", ext: "png", uti: "public.png", symbol: "photo"),
        Format(title: "JPEG", ext: "jpg", uti: "public.jpeg", symbol: "photo.fill", aliases: ["jpeg", "jpe"]),
        Format(title: "HEIC", ext: "heic", uti: "public.heic", symbol: "photo.badge.checkmark", aliases: ["heif"]),
        Format(title: "WebP", ext: "webp", uti: "org.webmproject.webp", symbol: "globe"),
        Format(title: "AVIF", ext: "avif", uti: "public.avif", symbol: "sparkles"),
        Format(title: "TIFF", ext: "tiff", uti: "public.tiff", symbol: "photo.stack", aliases: ["tif"]),
        Format(title: "GIF", ext: "gif", uti: "com.compuserve.gif", symbol: "square.stack.3d.forward.dottedline"),
        Format(title: "BMP", ext: "bmp", uti: "com.microsoft.bmp", symbol: "square.grid.3x3.fill"),
        Format(title: "JPEG 2000", ext: "jp2", uti: "public.jpeg-2000", symbol: "photo.circle"),
        Format(title: "ICO", ext: "ico", uti: "com.microsoft.ico", symbol: "app.dashed"),
        Format(title: "PSD", ext: "psd", uti: "com.adobe.photoshop-image", symbol: "paintbrush"),
        Format(title: "TGA", ext: "tga", uti: "com.truevision.tga-image", symbol: "gamecontroller"),
        Format(title: "OpenEXR", ext: "exr", uti: "com.ilm.openexr-image", symbol: "camera.aperture"),
        Format(title: "KTX2", ext: "ktx2", uti: "org.khronos.ktx2", symbol: "cube.transparent"),
        Format(title: "PBM", ext: "pbm", uti: "public.pbm", symbol: "circle.lefthalf.filled"),
    ]

    static var all: [FileAction] {
        var list: [FileAction] = formats.compactMap(formatAction)
        list += [
            FileAction(id: "image.pdf", title: "PDF", detail: "Convert image to a PDF page", symbol: "doc.richtext",
                       category: .image, accepts: inputs, mode: .each { url, ctx in
                let img = try ImageKit.load(url)
                let out = ctx.destination(for: url, ext: "pdf")
                try ImageKit.pdfData(for: [img]).write(to: out)
                return ActionOutput(files: [out])
            }),
            FileAction(id: "image.icns", title: "ICNS Icon", detail: "Make a macOS app icon (.icns)", symbol: "app.badge",
                       category: .image, accepts: inputs, sameFormat: ["icns"], mode: .each { url, ctx in
                ActionOutput(files: [try await makeICNS(url, ctx: ctx)])
            }),
            FileAction(id: "image.iconset", title: "App Icon Set", detail: "Export PNGs at every icon size (16–1024)", symbol: "square.grid.2x2",
                       category: .image, accepts: inputs, mode: .each { url, ctx in
                let img = try ImageKit.load(url)
                let dir = ctx.folder(for: url, suffix: "icons")
                for s in [16, 20, 29, 32, 40, 48, 58, 60, 64, 76, 80, 87, 120, 128, 152, 167, 180, 256, 512, 1024] {
                    try ImageKit.write(ImageKit.squareCanvas(img, side: s), to: dir.appendingPathComponent("icon-\(s).png"), type: "public.png")
                }
                return ActionOutput(files: [dir])
            }),
            transform("image.resize50", "Resize 50%", "Halve width and height", "arrow.down.right.and.arrow.up.left", "50%") { img in
                ImageKit.resize(img, width: img.width / 2, height: img.height / 2)
            },
            transform("image.resize25", "Resize 25%", "Quarter width and height", "arrow.down.forward.and.arrow.up.backward", "25%") { img in
                ImageKit.resize(img, width: img.width / 4, height: img.height / 4)
            },
            transform("image.resize200", "Upscale 2×", "Double width and height", "arrow.up.left.and.arrow.down.right", "2x") { img in
                ImageKit.resize(img, width: img.width * 2, height: img.height * 2)
            },
            transform("image.fit2048", "Max 2048 px", "Fit within 2048×2048", "rectangle.compress.vertical", "2048") { ImageKit.fit($0, maxSide: 2048) },
            transform("image.fit1024", "Max 1024 px", "Fit within 1024×1024", "rectangle.compress.vertical", "1024") { ImageKit.fit($0, maxSide: 1024) },
            transform("image.fit512", "Max 512 px", "Fit within 512×512", "rectangle.compress.vertical", "512") { ImageKit.fit($0, maxSide: 512) },
            transform("image.square", "Square Crop", "Crop to a centered square", "crop", "square") { img in
                let s = min(img.width, img.height)
                return img.cropping(to: CGRect(x: (img.width - s) / 2, y: (img.height - s) / 2, width: s, height: s)) ?? img
            },
            transform("image.rotateR", "Rotate Right", "Rotate 90° clockwise", "rotate.right", "rotated") { rotate($0, clockwise: true) },
            transform("image.rotateL", "Rotate Left", "Rotate 90° counter-clockwise", "rotate.left", "rotated") { rotate($0, clockwise: false) },
            transform("image.flipH", "Flip Horizontal", "Mirror left to right", "arrow.left.and.right.righttriangle.left.righttriangle.right", "flipped") { flip($0, horizontal: true) },
            transform("image.flipV", "Flip Vertical", "Mirror top to bottom", "arrow.up.and.down.righttriangle.up.righttriangle.down", "flipped") { flip($0, horizontal: false) },
            transform("image.gray", "Grayscale", "Convert to black & white", "circle.lefthalf.filled", "grayscale") { img in
                try ImageKit.filter(img) { i in let f = CIFilter.photoEffectNoir(); f.inputImage = i; return f.outputImage }
            },
            transform("image.sepia", "Sepia", "Apply a warm vintage tone", "camera.filters", "sepia") { img in
                try ImageKit.filter(img) { i in let f = CIFilter.sepiaTone(); f.inputImage = i; f.intensity = 0.9; return f.outputImage }
            },
            transform("image.invert", "Invert Colors", "Negative image", "circle.righthalf.filled.inverse", "inverted") { img in
                try ImageKit.filter(img) { i in let f = CIFilter.colorInvert(); f.inputImage = i; return f.outputImage }
            },
            transform("image.enhance", "Auto Enhance", "Apply automatic color and exposure fixes", "wand.and.stars", "enhanced") { img in
                try ImageKit.filter(img) { i in
                    i.autoAdjustmentFilters(options: [.redEye: false]).reduce(i) { acc, f in f.setValue(acc, forKey: kCIInputImageKey); return f.outputImage ?? acc }
                }
            },
            transform("image.strip", "Strip Metadata", "Remove EXIF, GPS and camera info", "eye.slash", "clean") { $0 },
            FileAction(id: "image.compress", title: "Compress", detail: "Smaller JPEG (60% quality)", symbol: "arrow.down.circle",
                       category: .image, accepts: inputs, mode: .each { url, ctx in
                let out = ctx.destination(for: url, ext: "jpg", suffix: "compressed")
                try ImageKit.write(try ImageKit.load(url), to: out, type: "public.jpeg", quality: 0.6)
                return ActionOutput(files: [out])
            }),
            FileAction(id: "image.removebg", title: "Remove Background", detail: "Lift the subject onto transparency (on-device)", symbol: "person.crop.rectangle.badge.plus",
                       category: .image, accepts: inputs, mode: .each { url, ctx in
                let out = ctx.destination(for: url, ext: "png", suffix: "no background")
                try ImageKit.write(try removeBackground(try ImageKit.load(url)), to: out, type: "public.png")
                return ActionOutput(files: [out])
            }),
            FileAction(id: "image.pdfcombine", title: "Combine to PDF", detail: "Put all images into one PDF", symbol: "doc.on.doc",
                       category: .image, accepts: inputs, minCount: 2, mode: .all { urls, ctx in
                let imgs = try urls.map { try ImageKit.load($0) }
                let out = FileNaming.unique(in: ctx.directory(for: urls[0]), base: "Combined", ext: "pdf")
                try ImageKit.pdfData(for: imgs).write(to: out)
                return ActionOutput(files: [out])
            }),
            FileAction(id: "image.gifanim", title: "Animated GIF", detail: "Make an animated GIF from the images", symbol: "play.square.stack",
                       category: .image, accepts: inputs, minCount: 2, mode: .all { urls, ctx in
                let imgs = try urls.map { ImageKit.fit(try ImageKit.load($0), maxSide: 800) }
                let w = imgs.map(\.width).max() ?? 1, h = imgs.map(\.height).max() ?? 1
                let frames = imgs.map { img in
                    ImageKit.draw(width: w, height: h) { c in
                        c.draw(img, in: CGRect(x: (w - img.width) / 2, y: (h - img.height) / 2, width: img.width, height: img.height))
                    } ?? img
                }
                let out = FileNaming.unique(in: ctx.directory(for: urls[0]), base: "Animation", ext: "gif")
                try ImageKit.writeGIF(frames, delay: 0.5, to: out)
                return ActionOutput(files: [out])
            }),
            FileAction(id: "image.info", title: "Image Info", detail: "Dimensions, color space and DPI", symbol: "info.circle",
                       category: .image, accepts: inputs, mode: .each { url, _ in
                let msg = imageInfo(url)
                return ActionOutput(message: msg, clipboard: msg)
            }),
        ]
        return list
    }

    static func formatAction(_ f: Format) -> FileAction? {
        let native = ImageKit.writableTypes.contains(f.uti)
        if !native && !(f.ext == "webp" && Tools.cwebp != nil) { return nil }
        return FileAction(id: "image.to.\(f.ext)", title: f.title, detail: "Convert to \(f.title)", symbol: f.symbol,
                          category: .image, accepts: inputs, sameFormat: f.aliases.union([f.ext]), mode: .each { url, ctx in
            let out = ctx.destination(for: url, ext: f.ext)
            if native {
                try ImageKit.write(try ImageKit.load(url), to: out, type: f.uti, quality: ctx.imageQuality)
            } else {
                try await writeWebP(url, to: out, quality: ctx.imageQuality)
            }
            return ActionOutput(files: [out])
        })
    }

    static func transform(_ id: String, _ title: String, _ detail: String, _ symbol: String, _ suffix: String,
                          _ body: @escaping @Sendable (CGImage) throws -> CGImage) -> FileAction {
        FileAction(id: id, title: title, detail: detail, symbol: symbol, category: .image, accepts: inputs, mode: .each { url, ctx in
            ActionOutput(files: [try ImageKit.writeMatching(try body(try ImageKit.load(url)), source: url, ctx: ctx, suffix: suffix)])
        })
    }

    static func rotate(_ img: CGImage, clockwise: Bool) -> CGImage {
        ImageKit.draw(width: img.height, height: img.width) { ctx in
            if clockwise {
                ctx.translateBy(x: 0, y: CGFloat(img.width)); ctx.rotate(by: -.pi / 2)
            } else {
                ctx.translateBy(x: CGFloat(img.height), y: 0); ctx.rotate(by: .pi / 2)
            }
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        } ?? img
    }

    static func flip(_ img: CGImage, horizontal: Bool) -> CGImage {
        ImageKit.draw(width: img.width, height: img.height) { ctx in
            if horizontal { ctx.translateBy(x: CGFloat(img.width), y: 0); ctx.scaleBy(x: -1, y: 1) }
            else { ctx.translateBy(x: 0, y: CGFloat(img.height)); ctx.scaleBy(x: 1, y: -1) }
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        } ?? img
    }

    static func makeICNS(_ url: URL, ctx: ActionContext) async throws -> URL {
        let img = try ImageKit.load(url)
        let fm = FileManager.default
        let set = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("iconset")
        try fm.createDirectory(at: set, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: set) }
        for base in [16, 32, 128, 256, 512] {
            try ImageKit.write(ImageKit.squareCanvas(img, side: base), to: set.appendingPathComponent("icon_\(base)x\(base).png"), type: "public.png")
            try ImageKit.write(ImageKit.squareCanvas(img, side: base * 2), to: set.appendingPathComponent("icon_\(base)x\(base)@2x.png"), type: "public.png")
        }
        let out = ctx.destination(for: url, ext: "icns")
        try await Shell.run("/usr/bin/iconutil", ["-c", "icns", set.path, "-o", out.path])
        return out
    }

    static func writeWebP(_ url: URL, to out: URL, quality: Double) async throws {
        // Normalize through PNG so any readable format works with the encoder.
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try ImageKit.write(try ImageKit.load(url), to: tmp, type: "public.png")
        let q = String(Int(quality * 100))
        if let cwebp = Tools.cwebp {
            try await Shell.run(cwebp, ["-quiet", "-q", q, "-alpha_q", "100", tmp.path, "-o", out.path])
        } else {
            throw ConvertError.missingTool("cwebp")
        }
    }

    static func removeBackground(_ img: CGImage) throws -> CGImage {
        let handler = VNImageRequestHandler(cgImage: img)
        let req = VNGenerateForegroundInstanceMaskRequest()
        try handler.perform([req])
        guard let obs = req.results?.first, !obs.allInstances.isEmpty else {
            throw ConvertError.failed("No subject found in the image.")
        }
        let buffer = try obs.generateMaskedImage(ofInstances: obs.allInstances, from: handler, croppedToInstancesExtent: false)
        let ci = CIImage(cvPixelBuffer: buffer)
        guard let cg = ImageKit.ciContext.createCGImage(ci, from: ci.extent) else { throw ConvertError.failed("Mask rendering failed.") }
        return cg
    }

    static func imageInfo(_ url: URL) -> String {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else {
            return "\(url.lastPathComponent): unreadable"
        }
        var parts = ["\(url.lastPathComponent)"]
        if let w = p[kCGImagePropertyPixelWidth], let h = p[kCGImagePropertyPixelHeight] { parts.append("\(w) × \(h) px") }
        if let m = p[kCGImagePropertyColorModel] { parts.append("\(m)") }
        if let d = p[kCGImagePropertyDepth] { parts.append("\(d)-bit") }
        if let dpi = p[kCGImagePropertyDPIWidth] { parts.append("\(dpi) dpi") }
        if let prof = p[kCGImagePropertyProfileName] { parts.append("\(prof)") }
        let frames = CGImageSourceGetCount(src)
        if frames > 1 { parts.append("\(frames) frames") }
        return parts.joined(separator: " · ")
    }
}
