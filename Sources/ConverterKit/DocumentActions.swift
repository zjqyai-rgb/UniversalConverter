import AppKit
import PDFKit

// MARK: - Markdown → HTML (CommonMark-ish subset)

public enum Markdown {
    public static func toHTML(_ md: String, title: String = "Document") -> String {
        """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8"><title>\(escape(title))</title>
        <style>
        body{font-family:-apple-system,Helvetica,Arial,sans-serif;max-width:760px;margin:40px auto;padding:0 20px;line-height:1.55;color:#222}
        pre{background:#f5f5f7;padding:12px;border-radius:6px;overflow:auto}code{font-family:Menlo,monospace;font-size:90%;background:#f5f5f7;padding:1px 4px;border-radius:4px}
        pre code{background:none;padding:0}blockquote{border-left:4px solid #ddd;margin:0;padding-left:16px;color:#555}
        table{border-collapse:collapse;width:100%}td,th{border:1px solid #ccc;padding:6px 10px}img{max-width:100%}
        </style></head><body>
        \(body(md))
        </body></html>
        """
    }

    public static func body(_ md: String) -> String {
        var html: [String] = []
        var paragraph: [String] = []
        var listStack: [String] = []
        var inCode = false
        var code: [String] = []
        var quote: [String] = []
        let lines = md.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")

        func flushParagraph() {
            if !paragraph.isEmpty { html.append("<p>\(inline(paragraph.joined(separator: " ")))</p>"); paragraph = [] }
        }
        func closeLists() { while let l = listStack.popLast() { html.append("</\(l)>") } }
        func flushQuote() {
            if !quote.isEmpty { html.append("<blockquote>\(body(quote.joined(separator: "\n")))</blockquote>"); quote = [] }
        }

        var i = 0
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            defer { i += 1 }

            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                if inCode {
                    html.append("<pre><code>\(escape(code.joined(separator: "\n")))</code></pre>"); code = []; inCode = false
                } else {
                    flushParagraph(); closeLists(); flushQuote(); inCode = true
                }
                continue
            }
            if inCode { code.append(line); continue }

            if trimmed.hasPrefix(">") {
                flushParagraph(); closeLists()
                quote.append(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)); continue
            } else { flushQuote() }

            if trimmed.isEmpty { flushParagraph(); closeLists(); continue }

            if let level = headingLevel(trimmed) {
                flushParagraph(); closeLists()
                let text = trimmed.dropFirst(level).trimmingCharacters(in: CharacterSet(charactersIn: "# "))
                html.append("<h\(level)>\(inline(text))</h\(level)>"); continue
            }
            if ["---", "***", "___"].contains(trimmed.replacingOccurrences(of: " ", with: "")) {
                flushParagraph(); closeLists(); html.append("<hr>"); continue
            }
            // Table: header row followed by a separator row.
            if trimmed.hasPrefix("|"), i + 1 < lines.count,
               lines[i + 1].trimmingCharacters(in: .whitespaces).range(of: #"^\|?[\s:\-|]+\|?$"#, options: .regularExpression) != nil {
                flushParagraph(); closeLists()
                func cells(_ s: String) -> [String] {
                    var t = s.trimmingCharacters(in: .whitespaces)
                    if t.hasPrefix("|") { t.removeFirst() }
                    if t.hasSuffix("|") { t.removeLast() }
                    return t.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                }
                var rows = ["<table><thead><tr>" + cells(trimmed).map { "<th>\(inline($0))</th>" }.joined() + "</tr></thead><tbody>"]
                i += 2
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    rows.append("<tr>" + cells(lines[i]).map { "<td>\(inline($0))</td>" }.joined() + "</tr>"); i += 1
                }
                i -= 1
                html.append(rows.joined() + "</tbody></table>"); continue
            }
            if let m = trimmed.range(of: #"^([-*+]|\d+[.)])\s+"#, options: .regularExpression) {
                flushParagraph()
                let ordered = trimmed.first?.isNumber == true
                let tag = ordered ? "ol" : "ul"
                if listStack.last != tag { closeLists(); listStack.append(tag); html.append("<\(tag)>") }
                var item = String(trimmed[m.upperBound...])
                if item.hasPrefix("[ ] ") { item = "☐ " + item.dropFirst(4) }
                if item.lowercased().hasPrefix("[x] ") { item = "☑ " + item.dropFirst(4) }
                html.append("<li>\(inline(item))</li>"); continue
            }
            if !listStack.isEmpty { closeLists() }
            paragraph.append(trimmed)
        }
        if inCode { html.append("<pre><code>\(escape(code.joined(separator: "\n")))</code></pre>") }
        flushParagraph(); closeLists(); flushQuote()
        return html.joined(separator: "\n")
    }

    static func headingLevel(_ s: String) -> Int? {
        let hashes = s.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(hashes), s.dropFirst(hashes).first == " " else { return nil }
        return hashes
    }

    static func inline(_ s: String) -> String {
        var t = escape(s)
        let rules: [(String, String)] = [
            (#"`([^`]+)`"#, "<code>$1</code>"),
            (#"!\[([^\]]*)\]\(([^)\s]+)\)"#, "<img alt=\"$1\" src=\"$2\">"),
            (#"\[([^\]]+)\]\(([^)\s]+)\)"#, "<a href=\"$2\">$1</a>"),
            (#"\*\*\*(.+?)\*\*\*"#, "<strong><em>$1</em></strong>"),
            (#"\*\*(.+?)\*\*"#, "<strong>$1</strong>"),
            (#"__(.+?)__"#, "<strong>$1</strong>"),
            (#"(?<![\w*])\*(?!\s)(.+?)(?<!\s)\*(?![\w*])"#, "<em>$1</em>"),
            (#"(?<!\w)_(?!\s)(.+?)(?<!\s)_(?!\w)"#, "<em>$1</em>"),
            (#"~~(.+?)~~"#, "<del>$1</del>"),
        ]
        for (pattern, template) in rules {
            t = t.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        return t
    }

    public static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}

// MARK: - Rich text I/O

@MainActor
public enum RichText {
    public static func load(_ url: URL) throws -> NSAttributedString {
        switch url.kind {
        case .markdown:
            let md = try String(contentsOf: url, encoding: .utf8)
            return try fromHTML(Markdown.toHTML(md, title: url.deletingPathExtension().lastPathComponent))
        case .pdf:
            guard let doc = PDFDocument(url: url) else { throw ConvertError.unreadable(url) }
            let result = NSMutableAttributedString()
            for i in 0..<doc.pageCount {
                if let s = doc.page(at: i)?.attributedString { result.append(s) }
                if i < doc.pageCount - 1 { result.append(NSAttributedString(string: "\n\n")) }
            }
            return result
        case .document, .html:
            return try NSAttributedString(url: url, options: [:], documentAttributes: nil)
        default:
            let text = try readText(url)
            return NSAttributedString(string: text, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                .foregroundColor: NSColor.black,
            ])
        }
    }

    public static func fromHTML(_ html: String) throws -> NSAttributedString {
        try NSAttributedString(data: Data(html.utf8), options: [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue,
        ], documentAttributes: nil)
    }

    public static func write(_ s: NSAttributedString, to url: URL, format: String) throws {
        let range = NSRange(location: 0, length: s.length)
        let types: [String: NSAttributedString.DocumentType] = [
            "rtf": .rtf, "docx": .officeOpenXML, "doc": .docFormat, "odt": .openDocument,
            "html": .html, "webarchive": .webArchive, "wordml": .wordML,
        ]
        switch format {
        case "txt":
            try s.string.write(to: url, atomically: true, encoding: .utf8)
        case "pdf":
            try renderPDF(s, to: url)
        case "rtfd":
            let wrapper = try s.fileWrapper(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd])
            try wrapper.write(to: url, options: .atomic, originalContentsURL: nil)
        case "md":
            try toMarkdown(s).write(to: url, atomically: true, encoding: .utf8)
        default:
            guard let type = types[format] else { throw ConvertError.failed("Unknown format \(format)") }
            let data = try s.data(from: range, documentAttributes: [.documentType: type])
            try data.write(to: url)
        }
    }

    /// Paginates through the AppKit text system so tables, images and colors survive.
    public static func renderPDF(_ s: NSAttributedString, to url: URL) throws {
        let paper = NSSize(width: 612, height: 792), margin: CGFloat = 54
        let width = paper.width - margin * 2
        let storage = NSTextStorage(attributedString: s)
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: paper)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { throw ConvertError.failed("PDF context failed") }
        let gc = NSGraphicsContext(cgContext: ctx, flipped: true)
        var pages = 0
        while true {
            let container = NSTextContainer(size: NSSize(width: width, height: paper.height - margin * 2))
            container.lineFragmentPadding = 0
            layout.addTextContainer(container)
            let glyphs = layout.glyphRange(for: container)
            if glyphs.length == 0 && pages > 0 { layout.removeTextContainer(at: layout.textContainers.count - 1); break }
            ctx.beginPDFPage(nil)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = gc
            ctx.translateBy(x: 0, y: paper.height); ctx.scaleBy(x: 1, y: -1)
            let origin = NSPoint(x: margin, y: margin)
            layout.drawBackground(forGlyphRange: glyphs, at: origin)
            layout.drawGlyphs(forGlyphRange: glyphs, at: origin)
            NSGraphicsContext.restoreGraphicsState()
            ctx.endPDFPage()
            pages += 1
            if NSMaxRange(glyphs) >= layout.numberOfGlyphs || pages > 5000 { break }
        }
        ctx.closePDF()
        try (data as Data).write(to: url)
    }

    /// Best-effort conversion of styled text back to Markdown.
    public static func toMarkdown(_ s: NSAttributedString) -> String {
        var out: [String] = []
        let ns = s.string as NSString
        var bodySize: CGFloat = 12
        // Most common font size is treated as body text.
        var sizes: [CGFloat: Int] = [:]
        s.enumerateAttribute(.font, in: NSRange(location: 0, length: s.length)) { v, r, _ in
            if let f = v as? NSFont { sizes[f.pointSize.rounded(), default: 0] += r.length }
        }
        if let top = sizes.max(by: { $0.value < $1.value }) { bodySize = top.key }

        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: .byParagraphs) { para, range, _, _ in
            guard let para else { return }
            if para.trimmingCharacters(in: .whitespaces).isEmpty { out.append(""); return }
            var line = ""
            var maxSize: CGFloat = 0
            var allBold = true
            s.enumerateAttributes(in: range) { attrs, r, _ in
                var piece = ns.substring(with: r)
                let font = attrs[.font] as? NSFont
                maxSize = max(maxSize, font?.pointSize ?? bodySize)
                let traits = font.map { NSFontManager.shared.traits(of: $0) } ?? []
                let bold = traits.contains(.boldFontMask), italic = traits.contains(.italicFontMask)
                if !bold && !piece.trimmingCharacters(in: .whitespaces).isEmpty { allBold = false }
                let core = piece.trimmingCharacters(in: .whitespaces)
                if !core.isEmpty {
                    var styled = core
                    if italic { styled = "*\(styled)*" }
                    if bold { styled = "**\(styled)**" }
                    if let link = attrs[.link] { styled = "[\(core)](\(link))" }
                    piece = piece.replacingOccurrences(of: core, with: styled)
                }
                line += piece
            }
            let plain = para.trimmingCharacters(in: .whitespaces)
            if maxSize >= bodySize * 1.7 { line = "# " + plain }
            else if maxSize >= bodySize * 1.35 { line = "## " + plain }
            else if maxSize >= bodySize * 1.15 || (allBold && plain.count < 80 && maxSize > bodySize) { line = "### " + plain }
            else if plain.hasPrefix("•") || plain.hasPrefix("◦") || plain.hasPrefix("▪") {
                line = "- " + line.trimmingCharacters(in: .whitespaces).dropFirst().trimmingCharacters(in: .whitespaces)
            }
            out.append(line.replacingOccurrences(of: "\t", with: " "))
        }
        return out.joined(separator: "\n\n").replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
    }

    public nonisolated static func readText(_ url: URL) throws -> String {
        if let s = try? String(contentsOf: url, encoding: .utf8) { return s }
        var enc = String.Encoding.utf8
        return try String(contentsOf: url, usedEncoding: &enc)
    }
}

// MARK: - Document actions

enum DocumentActions {
    static let richInputs: Set<FileKind> = [.document, .markdown, .html, .plainText, .pdf]

    struct Format { let title, ext, symbol, detail: String; var inputs: Set<FileKind> = DocumentActions.richInputs; var same: Set<String> = [] }

    static let formats: [Format] = [
        Format(title: "PDF", ext: "pdf", symbol: "doc.richtext", detail: "Paginated PDF (US Letter)",
               inputs: [.document, .markdown, .html, .plainText, .json, .csv, .tsv, .xml, .yaml, .plist], same: ["pdf"]),
        Format(title: "Word", ext: "docx", symbol: "doc.text", detail: "Microsoft Word (.docx)", same: ["docx"]),
        Format(title: "Word 97", ext: "doc", symbol: "doc", detail: "Legacy Word (.doc)", same: ["doc"]),
        Format(title: "RTF", ext: "rtf", symbol: "doc.plaintext", detail: "Rich Text Format", same: ["rtf"]),
        Format(title: "RTFD", ext: "rtfd", symbol: "doc.on.clipboard", detail: "Rich text with attachments", same: ["rtfd"]),
        Format(title: "OpenDocument", ext: "odt", symbol: "doc.badge.gearshape", detail: "LibreOffice / OpenOffice (.odt)", same: ["odt"]),
        Format(title: "HTML", ext: "html", symbol: "chevron.left.forwardslash.chevron.right", detail: "Web page", same: ["html", "htm"]),
        Format(title: "Web Archive", ext: "webarchive", symbol: "safari", detail: "Safari web archive", same: ["webarchive"]),
        Format(title: "Plain Text", ext: "txt", symbol: "text.alignleft", detail: "Unformatted UTF-8 text",
               inputs: [.document, .markdown, .html, .pdf], same: ["txt"]),
        Format(title: "Markdown", ext: "md", symbol: "number", detail: "Markdown text",
               inputs: [.document, .html, .pdf], same: ["md"]),
    ]

    static var all: [FileAction] {
        var list = formats.map { f in
            FileAction(id: "doc.to.\(f.ext)", title: f.title, detail: f.detail, symbol: f.symbol, category: .document,
                       accepts: f.inputs, sameFormat: f.same, mode: .each { url, ctx in
                let out = ctx.destination(for: url, ext: f.ext)
                // Markdown → HTML uses our own template for clean output.
                if url.kind == .markdown && f.ext == "html" {
                    let md = try RichText.readText(url)
                    try Markdown.toHTML(md, title: url.deletingPathExtension().lastPathComponent).write(to: out, atomically: true, encoding: .utf8)
                    return ActionOutput(files: [out])
                }
                if url.kind == .pdf && f.ext == "txt" {
                    guard let doc = PDFDocument(url: url) else { throw ConvertError.unreadable(url) }
                    try (doc.string ?? "").write(to: out, atomically: true, encoding: .utf8)
                    return ActionOutput(files: [out])
                }
                try await MainActor.run {
                    let s = try RichText.load(url)
                    try RichText.write(s, to: out, format: f.ext)
                }
                return ActionOutput(files: [out])
            })
        }
        list += [
            FileAction(id: "doc.speak", title: "Speak", detail: "Read aloud to an audio file (M4A)", symbol: "speaker.wave.3",
                       category: .document, accepts: [.plainText, .markdown, .document, .html, .pdf], mode: .each { url, ctx in
                let text: String
                if url.kind == .plainText { text = try RichText.readText(url) }
                else if url.kind == .pdf { text = PDFDocument(url: url)?.string ?? "" }
                else { text = try await MainActor.run { try RichText.load(url).string } }
                let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
                try text.write(to: tmp, atomically: true, encoding: .utf8)
                defer { try? FileManager.default.removeItem(at: tmp) }
                let out = ctx.destination(for: url, ext: "m4a", suffix: "spoken")
                try await Shell.run("/usr/bin/say", ["-f", tmp.path, "-o", out.path, "--file-format=m4af", "--data-format=aac"])
                return ActionOutput(files: [out])
            }),
            FileAction(id: "doc.count", title: "Word Count", detail: "Count words, lines and characters", symbol: "textformat.123",
                       category: .document, accepts: [.plainText, .markdown, .document, .html, .pdf, .csv, .json, .xml, .yaml], mode: .each { url, _ in
                let text: String
                switch url.kind {
                case .document, .html: text = try await MainActor.run { try RichText.load(url).string }
                case .pdf: text = PDFDocument(url: url)?.string ?? ""
                default: text = try RichText.readText(url)
                }
                var words = 0
                text.enumerateSubstrings(in: text.startIndex..., options: [.byWords, .substringNotRequired]) { _, _, _, _ in words += 1 }
                let lines = text.isEmpty ? 0 : text.components(separatedBy: .newlines).count
                let msg = "\(url.lastPathComponent): \(words) words · \(lines) lines · \(text.count) characters"
                return ActionOutput(message: msg, clipboard: msg)
            }),
            FileAction(id: "doc.combine", title: "Combine Text", detail: "Join all text files into one", symbol: "text.append",
                       category: .document, accepts: [.plainText, .markdown, .csv, .json, .yaml, .xml, .html], minCount: 2, mode: .all { urls, ctx in
                let parts = try urls.map { try RichText.readText($0) }
                let ext = Set(urls.map(\.ext)).count == 1 ? urls[0].ext : "txt"
                let out = FileNaming.unique(in: ctx.directory(for: urls[0]), base: "Combined", ext: ext)
                try parts.joined(separator: "\n\n").write(to: out, atomically: true, encoding: .utf8)
                return ActionOutput(files: [out])
            }),
        ]
        return list
    }
}

// MARK: - PDF actions

enum PDFActions {
    static let pdf: Set<FileKind> = [.pdf]

    static func open(_ url: URL) throws -> PDFDocument {
        guard let d = PDFDocument(url: url) else { throw ConvertError.unreadable(url) }
        if d.isLocked { throw ConvertError.failed("\(url.lastPathComponent) is password protected.") }
        return d
    }

    static func render(_ page: PDFPage, scale: CGFloat = 2) -> CGImage? {
        let b = page.bounds(for: .mediaBox)
        let rotated = page.rotation % 180 != 0
        let size = CGSize(width: (rotated ? b.height : b.width) * scale, height: (rotated ? b.width : b.height) * scale)
        return ImageKit.draw(width: Int(size.width), height: Int(size.height), opaque: true) { ctx in
            ctx.setFillColor(.white)
            ctx.fill(CGRect(origin: .zero, size: size))
            ctx.scaleBy(x: scale, y: scale)
            page.draw(with: .mediaBox, to: ctx)
        }
    }

    static func pagesToImages(_ title: String, ext: String, uti: String) -> FileAction {
        FileAction(id: "pdf.to.\(ext)", title: title, detail: "Every page as a \(title) image", symbol: "photo.on.rectangle",
                   category: .pdf, accepts: pdf, mode: .each { url, ctx in
            let doc = try open(url)
            if doc.pageCount == 1, let page = doc.page(at: 0), let img = render(page) {
                let out = ctx.destination(for: url, ext: ext)
                try ImageKit.write(img, to: out, type: uti, quality: ctx.imageQuality)
                return ActionOutput(files: [out])
            }
            let dir = ctx.folder(for: url, suffix: "pages")
            let digits = String(doc.pageCount).count
            for i in 0..<doc.pageCount {
                guard let page = doc.page(at: i), let img = render(page) else { continue }
                let name = "Page " + String(repeating: "0", count: digits - String(i + 1).count) + String(i + 1)
                try ImageKit.write(img, to: dir.appendingPathComponent(name).appendingPathExtension(ext), type: uti, quality: ctx.imageQuality)
                ctx.progress(Double(i + 1) / Double(doc.pageCount))
            }
            return ActionOutput(files: [dir])
        })
    }

    static func modify(_ id: String, _ title: String, _ detail: String, _ symbol: String, suffix: String,
                       _ body: @escaping @Sendable (PDFDocument) -> Void) -> FileAction {
        FileAction(id: id, title: title, detail: detail, symbol: symbol, category: .pdf, accepts: pdf, mode: .each { url, ctx in
            let doc = try open(url)
            body(doc)
            let out = ctx.destination(for: url, ext: "pdf", suffix: suffix)
            guard doc.write(to: out) else { throw ConvertError.failed("Couldn't save PDF.") }
            return ActionOutput(files: [out])
        })
    }

    static var all: [FileAction] {
        [
            pagesToImages("PNG Pages", ext: "png", uti: "public.png"),
            pagesToImages("JPEG Pages", ext: "jpg", uti: "public.jpeg"),
            pagesToImages("HEIC Pages", ext: "heic", uti: "public.heic"),
            pagesToImages("TIFF Pages", ext: "tiff", uti: "public.tiff"),
            FileAction(id: "pdf.merge", title: "Merge PDFs", detail: "Combine PDFs (and images) into one", symbol: "doc.on.doc",
                       category: .pdf, accepts: [.pdf, .image], minCount: 2, mode: .all { urls, ctx in
                guard urls.contains(where: { $0.kind == .pdf }) else { throw ConvertError.failed("Add at least one PDF.") }
                let merged = PDFDocument()
                for url in urls {
                    if url.kind == .pdf {
                        let d = try open(url)
                        for i in 0..<d.pageCount { if let p = d.page(at: i) { merged.insert(p, at: merged.pageCount) } }
                    } else if let ns = NSImage(contentsOf: url), let p = PDFPage(image: ns) {
                        merged.insert(p, at: merged.pageCount)
                    }
                }
                let out = FileNaming.unique(in: ctx.directory(for: urls[0]), base: "Merged", ext: "pdf")
                guard merged.write(to: out) else { throw ConvertError.failed("Couldn't save merged PDF.") }
                return ActionOutput(files: [out])
            }),
            FileAction(id: "pdf.split", title: "Split Pages", detail: "One PDF per page", symbol: "rectangle.split.3x1",
                       category: .pdf, accepts: pdf, mode: .each { url, ctx in
                let doc = try open(url)
                let dir = ctx.folder(for: url, suffix: "split")
                for i in 0..<doc.pageCount {
                    let single = PDFDocument()
                    if let p = doc.page(at: i)?.copy() as? PDFPage { single.insert(p, at: 0) }
                    single.write(to: dir.appendingPathComponent("Page \(i + 1).pdf"))
                }
                return ActionOutput(files: [dir])
            }),
            FileAction(id: "pdf.compress", title: "Compress PDF", detail: "Downsample and JPEG-encode images", symbol: "arrow.down.doc",
                       category: .pdf, accepts: pdf, mode: .each { url, ctx in
                let doc = try open(url)
                let out = ctx.destination(for: url, ext: "pdf", suffix: "compressed")
                let ok = doc.write(to: out, withOptions: [.saveImagesAsJPEGOption: true, .optimizeImagesForScreenOption: true])
                guard ok else { throw ConvertError.failed("Couldn't save PDF.") }
                let before = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                let after = (try? out.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                let f = ByteCountFormatter()
                return ActionOutput(files: [out], message: "\(url.lastPathComponent): \(f.string(fromByteCount: Int64(before))) → \(f.string(fromByteCount: Int64(after)))")
            }),
            FileAction(id: "pdf.flatten", title: "Flatten PDF", detail: "Rasterize pages (removes forms & layers)", symbol: "square.3.layers.3d.down.right",
                       category: .pdf, accepts: pdf, mode: .each { url, ctx in
                let doc = try open(url)
                var imgs: [CGImage] = []
                for i in 0..<doc.pageCount { if let p = doc.page(at: i), let img = render(p) { imgs.append(img) } }
                let data = NSMutableData()
                guard let consumer = CGDataConsumer(data: data as CFMutableData),
                      let c = CGContext(consumer: consumer, mediaBox: nil, nil) else { throw ConvertError.failed("PDF error") }
                for img in imgs {
                    var box = CGRect(x: 0, y: 0, width: CGFloat(img.width) / 2, height: CGFloat(img.height) / 2)
                    c.beginPage(mediaBox: &box); c.draw(img, in: box); c.endPage()
                }
                c.closePDF()
                let out = ctx.destination(for: url, ext: "pdf", suffix: "flattened")
                try (data as Data).write(to: out)
                return ActionOutput(files: [out])
            }),
            modify("pdf.rotate", "Rotate Pages", "Rotate every page 90° clockwise", "rotate.right", suffix: "rotated") { doc in
                for i in 0..<doc.pageCount { if let p = doc.page(at: i) { p.rotation = (p.rotation + 90) % 360 } }
            },
            modify("pdf.reverse", "Reverse Pages", "Reverse the page order", "arrow.uturn.backward", suffix: "reversed") { doc in
                let pages = (0..<doc.pageCount).compactMap { doc.page(at: $0) }
                for _ in pages { doc.removePage(at: 0) }
                for p in pages.reversed() { doc.insert(p, at: doc.pageCount) }
            },
            modify("pdf.oddeven", "Remove Even Pages", "Keep pages 1, 3, 5 …", "line.3.horizontal.decrease", suffix: "odd pages") { doc in
                var i = doc.pageCount - 1
                while i >= 0 { if i % 2 == 1 { doc.removePage(at: i) }; i -= 1 }
            },
            FileAction(id: "pdf.first", title: "First Page", detail: "Extract page 1 as its own PDF", symbol: "doc.badge.ellipsis",
                       category: .pdf, accepts: pdf, mode: .each { url, ctx in
                let doc = try open(url)
                let single = PDFDocument()
                if let p = doc.page(at: 0)?.copy() as? PDFPage { single.insert(p, at: 0) }
                let out = ctx.destination(for: url, ext: "pdf", suffix: "page 1")
                single.write(to: out)
                return ActionOutput(files: [out])
            }),
            FileAction(id: "pdf.info", title: "PDF Info", detail: "Pages, size, author and more", symbol: "info.circle",
                       category: .pdf, accepts: pdf, mode: .each { url, _ in
                guard let doc = PDFDocument(url: url) else { throw ConvertError.unreadable(url) }
                var parts = ["\(url.lastPathComponent): \(doc.pageCount) pages"]
                if let b = doc.page(at: 0)?.bounds(for: .mediaBox) { parts.append("\(Int(b.width))×\(Int(b.height)) pt") }
                let attrs = doc.documentAttributes ?? [:]
                for key in [PDFDocumentAttribute.titleAttribute, .authorAttribute, .creatorAttribute, .producerAttribute] {
                    if let v = attrs[key] as? String, !v.isEmpty { parts.append(v) }
                }
                if doc.isEncrypted { parts.append("encrypted") }
                let msg = parts.joined(separator: " · ")
                return ActionOutput(message: msg, clipboard: msg)
            }),
        ]
    }
}
