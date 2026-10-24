import Foundation
import UniformTypeIdentifiers

// MARK: - File kinds

public enum FileKind: String, CaseIterable, Sendable {
    case image, svg, video, audio, pdf, document, markdown, plainText, html, json, plist, csv, tsv, xml, yaml, archive, folder, other

    public static func of(_ url: URL) -> FileKind {
        let ext = url.pathExtension.lowercased()
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            return ext == "rtfd" ? .document : .folder
        }
        switch ext {
        case "md", "markdown", "mdown", "mkd", "mdx": return .markdown
        case "json", "geojson", "jsonl": return .json
        case "plist", "strings": return .plist
        case "csv": return .csv
        case "tsv", "tab": return .tsv
        case "yaml", "yml": return .yaml
        case "svg": return .svg
        case "html", "htm", "xhtml": return .html
        case "xml": return .xml
        case "rtf", "rtfd", "doc", "docx", "odt", "webarchive", "wordml", "pages": return .document
        case "txt", "text", "log", "nfo": return .plainText
        case "zip", "tar", "gz", "tgz", "bz2", "tbz", "xz", "txz", "7z", "rar", "cpio", "xar", "lz4", "zst", "iso":
            return .archive
        default: break
        }
        guard let type = UTType(filenameExtension: ext) else { return .other }
        if type.conforms(to: .pdf) { return .pdf }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        if type.conforms(to: .audio) { return .audio }
        if type.conforms(to: .archive) { return .archive }
        if type.conforms(to: .sourceCode) || type.conforms(to: .plainText) || type.conforms(to: .text) { return .plainText }
        return .other
    }

    /// Representative input extensions (used for counting supported conversions).
    public var knownExtensions: [String] {
        switch self {
        case .image: return ["png", "jpg", "jpeg", "heic", "heif", "tiff", "gif", "bmp", "webp", "avif", "jp2", "ico", "icns", "psd", "tga", "exr", "dng", "cr2", "cr3", "nef", "arw", "raf", "orf", "rw2", "dds", "ktx", "pbm", "jxl"]
        case .svg: return ["svg"]
        case .video: return ["mov", "mp4", "m4v", "3gp", "avi", "mkv", "webm", "mts"]
        case .audio: return ["mp3", "m4a", "wav", "aiff", "caf", "flac", "aac", "ogg", "opus", "ac3", "amr", "au", "m4r"]
        case .pdf: return ["pdf"]
        case .document: return ["rtf", "rtfd", "doc", "docx", "odt", "webarchive"]
        case .markdown: return ["md"]
        case .plainText: return ["txt", "log", "swift", "py", "js", "c"]
        case .html: return ["html"]
        case .json: return ["json"]
        case .plist: return ["plist"]
        case .csv: return ["csv"]
        case .tsv: return ["tsv"]
        case .xml: return ["xml"]
        case .yaml: return ["yaml"]
        case .archive: return ["zip", "tar", "tgz", "gz", "bz2", "xz", "7z", "rar"]
        case .folder: return ["folder"]
        case .other: return ["*"]
        }
    }

    public static let textual: Set<FileKind> = [.plainText, .markdown, .html, .json, .plist, .csv, .tsv, .xml, .yaml, .svg]
    public static let any: Set<FileKind> = Set(FileKind.allCases)
    public static let anyFile: Set<FileKind> = Set(FileKind.allCases).subtracting([.folder])
}

// MARK: - Actions

public enum ActionCategory: String, CaseIterable, Sendable {
    case image = "Image", video = "Video", audio = "Audio", document = "Document", pdf = "PDF",
         data = "Data", archive = "Archive", utility = "File Actions"
}

public struct ActionOutput: Sendable {
    public var files: [URL] = []
    public var message: String? = nil
    public var clipboard: String? = nil
    public init(files: [URL] = [], message: String? = nil, clipboard: String? = nil) {
        self.files = files; self.message = message; self.clipboard = clipboard
    }
    mutating func merge(_ other: ActionOutput) {
        files += other.files
        if let m = other.message { message = message.map { $0 + "\n" + m } ?? m }
        if let c = other.clipboard { clipboard = clipboard.map { $0 + "\n" + c } ?? c }
    }
}

public struct ActionContext: Sendable {
    /// nil = write next to the source file.
    public var outputDirectory: URL?
    public var imageQuality: Double
    public var progress: @Sendable (Double) -> Void

    public init(outputDirectory: URL? = nil, imageQuality: Double = 0.85, progress: @escaping @Sendable (Double) -> Void = { _ in }) {
        self.outputDirectory = outputDirectory
        self.imageQuality = imageQuality
        self.progress = progress
    }

    public func directory(for source: URL) -> URL {
        outputDirectory ?? source.deletingLastPathComponent()
    }

    /// A unique destination next to `source` (or in the output directory) named after it.
    public func destination(for source: URL, ext: String, suffix: String? = nil) -> URL {
        var base = source.deletingPathExtension().lastPathComponent
        if base.lowercased().hasSuffix(".tar") { base = String(base.dropLast(4)) }
        if let suffix { base += " (\(suffix))" }
        return FileNaming.unique(in: directory(for: source), base: base, ext: ext)
    }

    public func folder(for source: URL, suffix: String) -> URL {
        let base = source.deletingPathExtension().lastPathComponent + " (\(suffix))"
        let dir = FileNaming.unique(in: directory(for: source), base: base, ext: "")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

public enum FileNaming {
    public static func unique(in dir: URL, base: String, ext: String) -> URL {
        let fm = FileManager.default
        func make(_ n: Int) -> URL {
            let name = n == 1 ? base : "\(base) \(n)"
            return ext.isEmpty ? dir.appendingPathComponent(name) : dir.appendingPathComponent(name).appendingPathExtension(ext)
        }
        var n = 1
        while fm.fileExists(atPath: make(n).path) { n += 1 }
        return make(n)
    }
}

public struct FileAction: Identifiable, Sendable {
    public enum Mode: Sendable {
        /// Runs once per input file.
        case each(@Sendable (URL, ActionContext) async throws -> ActionOutput)
        /// Runs once with every input (merge, zip, ...).
        case all(@Sendable ([URL], ActionContext) async throws -> ActionOutput)
    }

    public let id: String
    public let title: String
    public let detail: String
    public let symbol: String
    public let category: ActionCategory
    public let accepts: Set<FileKind>
    /// Hidden when every input already has one of these extensions.
    public let sameFormat: Set<String>
    public let minCount: Int
    public let mode: Mode
    /// Optional extra per-file condition on top of the kind check.
    public var extraCondition: (@Sendable (URL) -> Bool)? = nil

    public init(id: String, title: String, detail: String, symbol: String, category: ActionCategory,
                accepts: Set<FileKind>, sameFormat: Set<String> = [], minCount: Int = 1, mode: Mode) {
        self.id = id; self.title = title; self.detail = detail; self.symbol = symbol
        self.category = category; self.accepts = accepts; self.sameFormat = sameFormat
        self.minCount = minCount; self.mode = mode
    }

    public func canHandle(_ urls: [URL]) -> Bool {
        guard urls.count >= minCount, !urls.isEmpty else { return false }
        guard urls.allSatisfy({ accepts.contains(FileKind.of($0)) }) else { return false }
        if let extraCondition, !urls.allSatisfy(extraCondition) { return false }
        if !sameFormat.isEmpty, urls.allSatisfy({ sameFormat.contains($0.pathExtension.lowercased()) }) { return false }
        return true
    }

    public func run(_ urls: [URL], context: ActionContext) async throws -> ActionOutput {
        switch mode {
        case .all(let body):
            let out = try await body(urls, context)
            context.progress(1)
            return out
        case .each(let body):
            var total = ActionOutput()
            var failures: [String] = []
            for (i, url) in urls.enumerated() {
                var sub = context
                let n = Double(urls.count)
                sub.progress = { p in context.progress((Double(i) + min(max(p, 0), 1)) / n) }
                do {
                    total.merge(try await body(url, sub))
                } catch {
                    if urls.count == 1 { throw error }
                    failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
                }
                context.progress(Double(i + 1) / n)
            }
            if !failures.isEmpty {
                if total.files.isEmpty && total.message == nil && total.clipboard == nil {
                    throw ConvertError.failed(failures.joined(separator: "\n"))
                }
                total.merge(ActionOutput(message: "Some files failed:\n" + failures.joined(separator: "\n")))
            }
            return total
        }
    }
}

public enum ConvertError: LocalizedError {
    case failed(String)
    case unreadable(URL)
    case missingTool(String)

    public var errorDescription: String? {
        switch self {
        case .failed(let s): return s
        case .unreadable(let u): return "Couldn't read \(u.lastPathComponent)."
        case .missingTool(let t): return "This action needs \(t), which isn't installed."
        }
    }
}

// MARK: - Process runner

public enum Shell {
    @discardableResult
    public static func run(_ executable: String, _ args: [String], cwd: URL? = nil, stdout: URL? = nil) async throws -> String {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("uc-\(UUID().uuidString)")
        let outFile = stdout ?? tmp.appendingPathExtension("out")
        let errFile = tmp.appendingPathExtension("err")
        fm.createFile(atPath: outFile.path, contents: nil)
        fm.createFile(atPath: errFile.path, contents: nil)
        defer {
            if stdout == nil { try? fm.removeItem(at: outFile) }
            try? fm.removeItem(at: errFile)
        }
        let outHandle = try FileHandle(forWritingTo: outFile)
        let errHandle = try FileHandle(forWritingTo: errFile)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
        if let cwd { p.currentDirectoryURL = cwd }
        p.standardOutput = outHandle
        p.standardError = errHandle
        p.standardInput = FileHandle.nullDevice

        let status: Int32 = try await withCheckedThrowingContinuation { cont in
            p.terminationHandler = { cont.resume(returning: $0.terminationStatus) }
            do { try p.run() } catch { cont.resume(throwing: error) }
        }
        try? outHandle.close(); try? errHandle.close()
        let out = stdout == nil ? (String(data: (try? Data(contentsOf: outFile)) ?? Data(), encoding: .utf8) ?? "") : ""
        if status != 0 {
            let err = String(data: (try? Data(contentsOf: errFile)) ?? Data(), encoding: .utf8) ?? ""
            let name = (executable as NSString).lastPathComponent
            throw ConvertError.failed("\(name) failed: \(err.trimmingCharacters(in: .whitespacesAndNewlines).suffix(400))")
        }
        return out
    }
}

public enum Tools {
    private static func find(_ name: String) -> String? {
        ["/opt/homebrew/bin/", "/usr/local/bin/", "/usr/bin/"].map { $0 + name }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }
    public static let ffmpeg = find("ffmpeg")
    public static let cwebp = find("cwebp")
}

extension URL {
    var kind: FileKind { FileKind.of(self) }
    var ext: String { pathExtension.lowercased() }
}
