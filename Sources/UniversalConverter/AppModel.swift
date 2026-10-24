import AppKit
import ConverterKit
import SwiftUI

enum OutputMode: String, CaseIterable, Identifiable {
    case source, downloads, desktop, custom
    var id: String { rawValue }
    var label: String {
        switch self {
        case .source: return "Next to the original"
        case .downloads: return "Downloads folder"
        case .desktop: return "Desktop"
        case .custom: return "Custom folder…"
        }
    }
}

enum Prefs {
    static let outputMode = "outputMode"
    static let customFolder = "customFolder"
    static let shiftDrag = "shiftDragEnabled"
    static let reveal = "revealAfterConvert"
    static let quality = "imageQuality"
    static let favorites = "favoriteActions"

    static func register() {
        UserDefaults.standard.register(defaults: [
            outputMode: OutputMode.source.rawValue, shiftDrag: true, reveal: false, quality: 0.85,
        ])
    }
}

@MainActor
final class Job: ObservableObject, Identifiable {
    enum State { case running, done, failed(String) }

    let id = UUID()
    let action: FileAction
    let inputs: [URL]
    let started = Date()
    @Published var progress: Double = 0
    @Published var state: State = .running
    @Published var output = ActionOutput()

    init(action: FileAction, inputs: [URL]) { self.action = action; self.inputs = inputs }

    var title: String {
        let what = inputs.count == 1 ? inputs[0].lastPathComponent : "\(inputs.count) files"
        return "\(what) → \(action.title)"
    }
    var isRunning: Bool { if case .running = state { return true }; return false }
    var failure: String? { if case .failed(let m) = state { return m }; return nil }
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published var jobs: [Job] = []
    @Published var selection: [URL] = []

    var favorites: [String] {
        get { UserDefaults.standard.stringArray(forKey: Prefs.favorites) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: Prefs.favorites); objectWillChange.send() }
    }

    func toggleFavorite(_ id: String) {
        if favorites.contains(id) { favorites.removeAll { $0 == id } } else { favorites.append(id) }
    }

    /// Actions for the files, favorites first, then grouped by category order.
    func actions(for urls: [URL]) -> [FileAction] {
        let list = ActionRegistry.actions(for: urls)
        let favs = favorites
        return list.filter { favs.contains($0.id) } + list.filter { !favs.contains($0.id) }
    }

    func outputDirectory() -> URL? {
        let d = UserDefaults.standard
        switch OutputMode(rawValue: d.string(forKey: Prefs.outputMode) ?? "") ?? .source {
        case .source: return nil
        case .downloads: return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        case .desktop: return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        case .custom: return d.string(forKey: Prefs.customFolder).map { URL(fileURLWithPath: $0) }
        }
    }

    @discardableResult
    func run(_ action: FileAction, on urls: [URL]) -> Job {
        let job = Job(action: action, inputs: urls)
        jobs.insert(job, at: 0)
        if jobs.count > 100 { jobs.removeLast(jobs.count - 100) }

        let ctx = ActionContext(
            outputDirectory: outputDirectory(),
            imageQuality: UserDefaults.standard.double(forKey: Prefs.quality),
            progress: { [weak job] p in Task { @MainActor in job?.progress = p } }
        )
        Task {
            do {
                let out = try await action.run(urls, context: ctx)
                job.output = out
                job.progress = 1
                job.state = .done
                if let text = out.clipboard {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                if UserDefaults.standard.bool(forKey: Prefs.reveal), !out.files.isEmpty {
                    NSWorkspace.shared.activateFileViewerSelecting(out.files)
                }
            } catch {
                job.state = .failed(error.localizedDescription)
            }
        }
        return job
    }

    func clearFinished() { jobs.removeAll { !$0.isRunning } }
}

extension ActionCategory {
    var color: Color {
        switch self {
        case .image: return .orange
        case .video: return .purple
        case .audio: return .pink
        case .document: return .blue
        case .pdf: return .red
        case .data: return .teal
        case .archive: return .brown
        case .utility: return .gray
        }
    }
    var symbol: String {
        switch self {
        case .image: return "photo"
        case .video: return "film"
        case .audio: return "waveform"
        case .document: return "doc.text"
        case .pdf: return "doc.richtext"
        case .data: return "curlybraces"
        case .archive: return "archivebox"
        case .utility: return "wrench.and.screwdriver"
        }
    }
}
