import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import CryptoKit
import PDFKit
import UniformTypeIdentifiers
import Vision

// MARK: - Archives (bsdtar / ditto / hdiutil, all built into macOS)

enum ArchiveActions {
    /// bsdtar args that add each item relative to its own parent folder.
    static func members(_ urls: [URL]) -> [String] {
        urls.flatMap { ["-C", $0.deletingLastPathComponent().path, $0.lastPathComponent] }
    }

    static func archiveName(_ urls: [URL]) -> String {
        urls.count == 1 ? urls[0].deletingPathExtension().lastPathComponent : "Archive"
    }

    static func compress(_ id: String, _ title: String, _ detail: String, _ symbol: String, ext: String, flags: [String]) -> FileAction {
        FileAction(id: id, title: title, detail: detail, symbol: symbol, category: .archive, accepts: FileKind.any, mode: .all { urls, ctx in
            let out = FileNaming.unique(in: ctx.directory(for: urls[0]), base: archiveName(urls), ext: ext)
            if ext == "zip", urls.count == 1 {
                // ditto produces the same archive as Finder's Compress.
                try await Shell.run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", urls[0].path, out.path])
            } else {
                try await Shell.run("/usr/bin/tar", flags + ["--no-mac-metadata", "--exclude", ".DS_Store", "-f", out.path] + members(urls))
            }
            return ActionOutput(files: [out])
        })
    }

    static var all: [FileAction] {
        [
            compress("archive.zip", "ZIP", "Compress into a .zip", "doc.zipper", ext: "zip", flags: ["--format", "zip", "-c"]),
            compress("archive.tgz", "tar.gz", "Gzip-compressed tarball", "archivebox", ext: "tar.gz", flags: ["-cz"]),
            compress("archive.tbz", "tar.bz2", "Bzip2-compressed tarball", "archivebox.fill", ext: "tar.bz2", flags: ["-cj"]),
            compress("archive.txz", "tar.xz", "XZ-compressed tarball (smallest)", "shippingbox.fill", ext: "tar.xz", flags: ["-cJ"]),
            compress("archive.tar", "TAR", "Uncompressed tarball", "tray.full", ext: "tar", flags: ["-c"]),
            compress("archive.7z", "7z", "7-Zip archive", "cube.box", ext: "7z", flags: ["--format", "7zip", "-c"]),
            FileAction(id: "archive.gzip", title: "Gzip", detail: "Gzip a single file (.gz)", symbol: "arrow.down.right.and.arrow.up.left",
                       category: .archive, accepts: FileKind.anyFile, sameFormat: ["gz", "tgz"], mode: .each { url, ctx in
                let out = FileNaming.unique(in: ctx.directory(for: url), base: url.lastPathComponent, ext: "gz")
                try await Shell.run("/usr/bin/gzip", ["-c", "-9", url.path], stdout: out)
                return ActionOutput(files: [out])
            }),
            FileAction(id: "archive.dmg", title: "Disk Image", detail: "Compressed .dmg from a folder", symbol: "externaldrive",
                       category: .archive, accepts: [.folder], mode: .each { url, ctx in
                let out = ctx.destination(for: url, ext: "dmg")
                try await Shell.run("/usr/bin/hdiutil", ["create", "-quiet", "-volname", url.lastPathComponent, "-srcfolder", url.path,
                                                         "-ov", "-format", "UDZO", out.path])
                return ActionOutput(files: [out])
            }),
            FileAction(id: "archive.extract", title: "Extract", detail: "Unpack zip, tar, gz, bz2, xz, 7z, rar…", symbol: "arrow.up.bin",
                       category: .archive, accepts: [.archive], mode: .each { url, ctx in
                let name = url.lastPathComponent.lowercased()
                let isTar = name.contains(".tar.") || ["tar", "tgz", "tbz", "txz", "zip", "7z", "rar", "cpio", "xar", "iso"].contains(url.ext)
                if !isTar, let tool = ["gz": "/usr/bin/gunzip", "bz2": "/usr/bin/bunzip2"][url.ext] {
                    let out = FileNaming.unique(in: ctx.directory(for: url), base: url.deletingPathExtension().deletingPathExtension().lastPathComponent,
                                                ext: url.deletingPathExtension().pathExtension)
                    try await Shell.run(tool, ["-c", url.path], stdout: out)
                    return ActionOutput(files: [out])
                }
                var base = url.deletingPathExtension().lastPathComponent
                if base.lowercased().hasSuffix(".tar") { base = String(base.dropLast(4)) }
                let dir = FileNaming.unique(in: ctx.directory(for: url), base: base, ext: "")
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                do {
                    try await Shell.run("/usr/bin/tar", ["-xf", url.path, "-C", dir.path])
                } catch {
                    try? FileManager.default.removeItem(at: dir); throw error
                }
                // Unwrap a single top-level folder so we don't get "name/name/…".
                let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?
                    .filter { $0.lastPathComponent != "__MACOSX" && $0.lastPathComponent != ".DS_Store" } ?? []
                try? FileManager.default.removeItem(at: dir.appendingPathComponent("__MACOSX"))
                if items.count == 1, items[0].kind == .folder {
                    let target = FileNaming.unique(in: dir.deletingLastPathComponent(), base: items[0].lastPathComponent, ext: "")
                    let tmp = dir.deletingLastPathComponent().appendingPathComponent(".uc-\(UUID().uuidString)")
                    try FileManager.default.moveItem(at: items[0], to: tmp)
                    try FileManager.default.removeItem(at: dir)
                    try FileManager.default.moveItem(at: tmp, to: target)
                    return ActionOutput(files: [target])
                }
                return ActionOutput(files: [dir])
            }),
            FileAction(id: "archive.list", title: "List Contents", detail: "Show what's inside the archive", symbol: "list.bullet",
                       category: .archive, accepts: [.archive], mode: .each { url, _ in
                let list = try await Shell.run("/usr/bin/tar", ["-tf", url.path])
                let entries = list.split(separator: "\n")
                let msg = "\(url.lastPathComponent): \(entries.count) items\n" + entries.prefix(40).joined(separator: "\n")
                    + (entries.count > 40 ? "\n…" : "")
                return ActionOutput(message: msg, clipboard: list)
            }),
        ]
    }
}

// MARK: - General file actions

enum UtilityActions {
    static func hash<H: HashFunction>(_ url: URL, _ h: H.Type) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = H()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func checksum(_ name: String, _ body: @escaping @Sendable (URL) throws -> String) -> FileAction {
        FileAction(id: "util.\(name.lowercased().replacingOccurrences(of: "-", with: ""))", title: name, detail: "Copy the \(name) checksum",
                   symbol: "number.square", category: .utility, accepts: FileKind.anyFile, mode: .each { url, _ in
            let h = try body(url)
            return ActionOutput(message: "\(name) \(url.lastPathComponent)\n\(h)", clipboard: h)
        })
    }

    static func rename(_ id: String, _ title: String, _ detail: String, _ symbol: String, _ transform: @escaping @Sendable (String) -> String) -> FileAction {
        FileAction(id: id, title: title, detail: detail, symbol: symbol, category: .utility, accepts: FileKind.any, mode: .each { url, _ in
            let ext = url.pathExtension
            let newBase = transform(url.deletingPathExtension().lastPathComponent)
            let target = url.deletingLastPathComponent().appendingPathComponent(ext.isEmpty ? newBase : newBase + "." + ext)
            guard target.lastPathComponent != url.lastPathComponent else { return ActionOutput(files: [url]) }
            if target.path.lowercased() == url.path.lowercased() { // case-only rename on a case-insensitive volume
                let tmp = url.deletingLastPathComponent().appendingPathComponent(".uc-\(UUID().uuidString)")
                try FileManager.default.moveItem(at: url, to: tmp)
                try FileManager.default.moveItem(at: tmp, to: target)
            } else {
                guard !FileManager.default.fileExists(atPath: target.path) else { throw ConvertError.failed("\(target.lastPathComponent) already exists.") }
                try FileManager.default.moveItem(at: url, to: target)
            }
            return ActionOutput(files: [target])
        })
    }

    static func slug(_ s: String, sep: String) -> String {
        let folded = s.applyingTransform(.toLatin, reverse: false)?.applyingTransform(.stripDiacritics, reverse: false) ?? s
        var spaced = folded.replacingOccurrences(of: #"([a-z0-9])([A-Z])"#, with: "$1 $2", options: .regularExpression)
        spaced = spaced.lowercased().replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
        return spaced.split(separator: " ").joined(separator: sep)
    }

    static func ocr(_ img: CGImage) throws -> String {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = true
        req.automaticallyDetectsLanguage = true
        try VNImageRequestHandler(cgImage: img).perform([req])
        return (req.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    static var all: [FileAction] {
        [
            FileAction(id: "util.ocr", title: "Extract Text", detail: "OCR images & scanned PDFs (on-device)", symbol: "text.viewfinder",
                       category: .utility, accepts: [.image, .pdf], mode: .each { url, ctx in
                var pages: [String] = []
                if url.kind == .pdf {
                    let doc = try PDFActions.open(url)
                    for i in 0..<doc.pageCount {
                        if let p = doc.page(at: i), let img = PDFActions.render(p) { pages.append(try ocr(img)) }
                        ctx.progress(Double(i + 1) / Double(doc.pageCount))
                    }
                } else {
                    pages = [try ocr(try ImageKit.load(url))]
                }
                let text = pages.joined(separator: "\n\n")
                guard !text.isEmpty else { throw ConvertError.failed("No text found in \(url.lastPathComponent).") }
                let out = ctx.destination(for: url, ext: "txt", suffix: "text")
                try text.write(to: out, atomically: true, encoding: .utf8)
                return ActionOutput(files: [out], clipboard: text)
            }),
            FileAction(id: "util.qrread", title: "Read QR / Barcode", detail: "Decode codes in an image", symbol: "qrcode.viewfinder",
                       category: .utility, accepts: [.image], mode: .each { url, _ in
                let req = VNDetectBarcodesRequest()
                try VNImageRequestHandler(cgImage: try ImageKit.load(url)).perform([req])
                let codes = (req.results ?? []).compactMap(\.payloadStringValue)
                guard !codes.isEmpty else { throw ConvertError.failed("No QR code or barcode found.") }
                return ActionOutput(message: codes.joined(separator: "\n"), clipboard: codes.joined(separator: "\n"))
            }),
            FileAction(id: "util.qrmake", title: "QR Code", detail: "Encode the text as a QR code PNG", symbol: "qrcode",
                       category: .utility, accepts: [.plainText, .markdown, .json, .csv, .yaml, .xml], mode: .each { url, ctx in
                let text = try RichText.readText(url).trimmingCharacters(in: .whitespacesAndNewlines)
                guard text.utf8.count <= 2900 else { throw ConvertError.failed("Too much text for a QR code (max ~2,900 bytes).") }
                let f = CIFilter.qrCodeGenerator()
                f.message = Data(text.utf8); f.correctionLevel = "M"
                guard let ci = f.outputImage?.transformed(by: CGAffineTransform(scaleX: 12, y: 12)),
                      let img = ImageKit.ciContext.createCGImage(ci, from: ci.extent) else { throw ConvertError.failed("QR generation failed.") }
                let out = ctx.destination(for: url, ext: "png", suffix: "QR")
                try ImageKit.write(img, to: out, type: "public.png")
                return ActionOutput(files: [out])
            }),
            FileAction(id: "util.copypath", title: "Copy Path", detail: "Copy full paths to the clipboard", symbol: "doc.on.clipboard",
                       category: .utility, accepts: FileKind.any, mode: .all { urls, _ in
                let s = urls.map(\.path).joined(separator: "\n")
                return ActionOutput(message: "Copied \(urls.count == 1 ? "path" : "\(urls.count) paths")", clipboard: s)
            }),
            FileAction(id: "util.copyname", title: "Copy Name", detail: "Copy file names to the clipboard", symbol: "character.cursor.ibeam",
                       category: .utility, accepts: FileKind.any, mode: .all { urls, _ in
                ActionOutput(message: "Copied \(urls.count) name(s)", clipboard: urls.map(\.lastPathComponent).joined(separator: "\n"))
            }),
            checksum("SHA-256") { try hash($0, SHA256.self) },
            checksum("SHA-1") { try hash($0, Insecure.SHA1.self) },
            checksum("MD5") { try hash($0, Insecure.MD5.self) },
            FileAction(id: "util.base64", title: "Base64", detail: "Encode the file as Base64 text", symbol: "textformat.abc",
                       category: .utility, accepts: FileKind.anyFile, mode: .each { url, ctx in
                let data = try Data(contentsOf: url)
                let out = FileNaming.unique(in: ctx.directory(for: url), base: url.lastPathComponent, ext: "b64")
                try data.base64EncodedString(options: .lineLength76Characters).write(to: out, atomically: true, encoding: .utf8)
                return ActionOutput(files: [out])
            }),
            FileAction(id: "util.datauri", title: "Data URI", detail: "Copy as a data: URI for HTML/CSS", symbol: "link",
                       category: .utility, accepts: [.image, .svg, .audio, .pdf], mode: .each { url, _ in
                let data = try Data(contentsOf: url)
                guard data.count < 10 << 20 else { throw ConvertError.failed("File is too large for a data URI.") }
                let mime = UTType(filenameExtension: url.ext)?.preferredMIMEType ?? "application/octet-stream"
                let uri = "data:\(mime);base64,\(data.base64EncodedString())"
                return ActionOutput(message: "Copied data URI (\(ByteCountFormatter().string(fromByteCount: Int64(uri.count))))", clipboard: uri)
            }),
            FileAction(id: "util.b64decode", title: "Decode Base64", detail: "Turn .b64 text back into the original file", symbol: "textformat.abc.dottedunderline",
                       category: .utility, accepts: FileKind.anyFile, mode: .each { url, ctx in
                let text = try String(contentsOf: url, encoding: .utf8)
                    .replacingOccurrences(of: #"^data:[^,]*,"#, with: "", options: .regularExpression)
                guard let data = Data(base64Encoded: text, options: .ignoreUnknownCharacters), !data.isEmpty else {
                    throw ConvertError.failed("\(url.lastPathComponent) isn't valid Base64.")
                }
                let name = url.deletingPathExtension()
                let out = FileNaming.unique(in: ctx.directory(for: url), base: name.deletingPathExtension().lastPathComponent,
                                            ext: name.pathExtension.isEmpty ? "bin" : name.pathExtension)
                try data.write(to: out)
                return ActionOutput(files: [out])
            }).filtered { $0.ext == "b64" || $0.ext == "base64" },
            FileAction(id: "util.duplicate", title: "Duplicate", detail: "Make a copy alongside the original", symbol: "plus.square.on.square",
                       category: .utility, accepts: FileKind.any, mode: .each { url, ctx in
                let out = FileNaming.unique(in: ctx.directory(for: url), base: url.deletingPathExtension().lastPathComponent + " copy", ext: url.pathExtension)
                try FileManager.default.copyItem(at: url, to: out)
                return ActionOutput(files: [out])
            }),
            FileAction(id: "util.unquarantine", title: "Unquarantine", detail: "Remove the “downloaded from the internet” flag", symbol: "checkmark.shield",
                       category: .utility, accepts: FileKind.any, mode: .each { url, _ in
                _ = try? await Shell.run("/usr/bin/xattr", ["-r", "-d", "com.apple.quarantine", url.path]) // fails if absent
                return ActionOutput(message: "Cleared quarantine on \(url.lastPathComponent)")
            }),
            FileAction(id: "util.info", title: "File Info", detail: "Size, dates and type", symbol: "info.circle",
                       category: .utility, accepts: FileKind.any, mode: .each { url, _ in
                let v = try url.resourceValues(forKeys: [.fileSizeKey, .totalFileAllocatedSizeKey, .creationDateKey, .contentModificationDateKey, .localizedTypeDescriptionKey])
                var size = Int64(v.fileSize ?? 0)
                if url.kind == .folder, let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) {
                    for case let f as URL in e.allObjects { size += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
                }
                let df = DateFormatter(); df.dateStyle = .medium; df.timeStyle = .short
                let msg = [url.lastPathComponent, v.localizedTypeDescription ?? "",
                           ByteCountFormatter().string(fromByteCount: size),
                           "Created " + (v.creationDate.map(df.string) ?? "?"),
                           "Modified " + (v.contentModificationDate.map(df.string) ?? "?")].joined(separator: " · ")
                return ActionOutput(message: msg, clipboard: msg)
            }),
            rename("util.lower", "lowercase", "Rename to lowercase", "textformat.size.smaller") { $0.lowercased() },
            rename("util.kebab", "kebab-case", "Rename to kebab-case", "minus") { slug($0, sep: "-") },
            rename("util.snake", "snake_case", "Rename to snake_case", "underscore") { slug($0, sep: "_") },
            rename("util.title", "Title Case", "Rename To Title Case", "textformat") { slug($0, sep: " ").capitalized },
            rename("util.date", "Date Prefix", "Prefix the name with today's date", "calendar") { name in
                let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
                return f.string(from: Date()) + " " + name
            },
        ]
    }
}

extension FileAction {
    /// Adds an extra per-file condition on top of the kind check.
    func filtered(_ condition: @escaping @Sendable (URL) -> Bool) -> FileAction {
        var copy = self
        copy.extraCondition = condition
        return copy
    }
}

// MARK: - Registry

public enum ActionRegistry {
    public static let all: [FileAction] = {
        let list = ImageActions.all + MediaActions.all + DocumentActions.all + PDFActions.all
            + DataActions.all + ArchiveActions.all + UtilityActions.all
        return list
    }()

    public static func actions(for urls: [URL]) -> [FileAction] {
        all.filter { $0.canHandle(urls) }
    }

    public static func action(id: String) -> FileAction? { all.first { $0.id == id } }

    /// Number of distinct input-format → action pairs supported.
    public static var conversionCount: Int {
        all.reduce(0) { sum, a in
            sum + a.accepts.reduce(0) { s, k in
                s + k.knownExtensions.filter { !a.sameFormat.contains($0) }.count
            }
        }
    }
}
