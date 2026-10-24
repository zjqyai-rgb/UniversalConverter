import AppKit
import ConverterKit
import SwiftUI
import UniformTypeIdentifiers

struct MainView: View {
    @ObservedObject private var model = AppModel.shared
    @Local private var search = ""
    @Local private var dropTargeted = false

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                if model.selection.isEmpty { emptyState } else { chooser }
            }
            .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
            ActivityView()
                .frame(minWidth: 260, idealWidth: 300, maxWidth: 420)
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            loadURLs(providers) { urls in if !urls.isEmpty { model.selection = urls; search = "" } }
            return true
        }
        .toolbar {
            ToolbarItem {
                Button { chooseFiles() } label: { Label("Choose Files", systemImage: "plus") }
                    .help("Choose files to convert")
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 18) {
            Spacer()
            ZStack {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 2.5, dash: [9, 7]))
                    .foregroundStyle(dropTargeted ? Color.orange : Color.secondary.opacity(0.4))
                    .background(RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(dropTargeted ? Color.orange.opacity(0.08) : Color.clear))
                VStack(spacing: 12) {
                    Image(systemName: "arrow.down.doc")
                        .font(.system(size: 46, weight: .light))
                        .foregroundStyle(.orange)
                    Text("Drop files here").font(.title2.weight(.semibold))
                    Text("Images, video, audio, documents, PDFs, data, archives — anything.")
                        .foregroundStyle(.secondary)
                    Button("Choose Files…") { chooseFiles() }
                        .controlSize(.large)
                        .keyboardShortcut("o")
                }
                .padding(30)
            }
            .frame(maxWidth: 520, maxHeight: 280)
            HStack(spacing: 10) {
                Image(systemName: "shift").font(.title3).foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Shift-drag from anywhere").font(.headline)
                    Text("Start dragging files in Finder, hold **⇧ Shift**, and drop them onto a format in the panel that pops up.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .frame(maxWidth: 520)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.orange.opacity(0.08)))
            Text("\(ActionRegistry.all.count) actions · \(ActionRegistry.conversionCount.formatted()) format combinations · 100% offline")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(30)
        .frame(maxWidth: .infinity)
    }

    private var chooser: some View {
        let all = model.actions(for: model.selection)
        let filtered = search.isEmpty ? all : all.filter {
            $0.title.localizedCaseInsensitiveContains(search) || $0.detail.localizedCaseInsensitiveContains(search)
                || $0.category.rawValue.localizedCaseInsensitiveContains(search)
        }
        return VStack(spacing: 0) {
            HStack(spacing: 12) {
                FileStack(urls: model.selection).frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.selection.count == 1 ? model.selection[0].lastPathComponent : "\(model.selection.count) files")
                        .font(.headline).lineLimit(1).truncationMode(.middle)
                    Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                TextField("Search \(all.count) actions", text: $search)
                    .textFieldStyle(.roundedBorder).frame(width: 200)
                Button { model.selection = [] } label: { Image(systemName: "xmark") }
                    .help("Clear selection")
            }
            .padding(14)
            Divider()
            ScrollView {
                if filtered.isEmpty {
                    Text(all.isEmpty ? "No actions work on this combination of files." : "No matching actions.")
                        .foregroundStyle(.secondary).padding(40)
                } else {
                    ActionGrid(actions: filtered, mode: .click { action in
                        model.run(action, on: model.selection)
                    }, favorites: model.favorites)
                    .padding(16)
                }
            }
            Divider()
            Text("Tip: right-click a tile to add it to Favorites — favorites show first in the Shift-drag panel.")
                .font(.caption).foregroundStyle(.secondary).padding(8)
        }
    }

    private var summary: String {
        let kinds = Set(model.selection.map { FileKind.of($0).rawValue })
        let size = model.selection.reduce(Int64(0)) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        return kinds.sorted().joined(separator: ", ") + " · " + ByteCountFormatter().string(fromByteCount: size)
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        if panel.runModal() == .OK { model.selection = panel.urls; search = "" }
    }
}

struct ActivityView: View {
    @ObservedObject private var model = AppModel.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Activity").font(.headline)
                Spacer()
                if model.jobs.contains(where: { !$0.isRunning }) {
                    Button("Clear") { model.clearFinished() }.controlSize(.small)
                }
            }
            .padding(12)
            Divider()
            if model.jobs.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "clock.arrow.circlepath").font(.largeTitle).foregroundStyle(.tertiary)
                    Text("Conversions will appear here").foregroundStyle(.secondary).font(.callout)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(model.jobs) { job in JobRow(job: job) }
                    .listStyle(.plain)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

struct JobRow: View {
    @ObservedObject var job: Job

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: job.action.symbol)
                .foregroundStyle(job.action.category.color)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(job.title).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                switch job.state {
                case .running:
                    ProgressView(value: job.progress).controlSize(.small)
                case .failed(let msg):
                    Text(msg).font(.caption).foregroundStyle(.red).lineLimit(3).textSelection(.enabled)
                case .done:
                    if let m = job.output.message {
                        Text(m).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(3).textSelection(.enabled)
                    }
                    if !job.output.files.isEmpty {
                        Text(job.output.files.map(\.lastPathComponent).joined(separator: ", "))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
            }
            Spacer(minLength: 0)
            if case .done = job.state, !job.output.files.isEmpty {
                Button { NSWorkspace.shared.activateFileViewerSelecting(job.output.files) } label: {
                    Image(systemName: "magnifyingglass.circle.fill")
                }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Show in Finder")
            } else if case .failed = job.state {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 3)
        .contextMenu {
            if !job.output.files.isEmpty {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(job.output.files) }
                Button("Open") { job.output.files.forEach { NSWorkspace.shared.open($0) } }
                Button("Convert Again…") { AppModel.shared.selection = job.output.files }
            }
            Button("Show Originals") { NSWorkspace.shared.activateFileViewerSelecting(job.inputs) }
        }
    }
}

struct SettingsView: View {
    @AppStorage(Prefs.outputMode) private var outputMode = OutputMode.source.rawValue
    @AppStorage(Prefs.customFolder) private var customFolder = ""
    @AppStorage(Prefs.shiftDrag) private var shiftDrag = true
    @AppStorage(Prefs.reveal) private var reveal = false
    @AppStorage(Prefs.quality) private var quality = 0.85

    var body: some View {
        Form {
            Section("Shift-Drag Panel") {
                Toggle("Show the format panel when I hold Shift while dragging files", isOn: $shiftDrag)
                Text("Works in Finder and any app you can drag files from. No special permissions needed.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Output") {
                Picker("Save converted files", selection: $outputMode) {
                    ForEach(OutputMode.allCases) { Text($0.label).tag($0.rawValue) }
                }
                if outputMode == OutputMode.custom.rawValue {
                    HStack {
                        Text(customFolder.isEmpty ? "No folder chosen" : customFolder)
                            .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                        Spacer()
                        Button("Choose…") {
                            let p = NSOpenPanel()
                            p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
                            if p.runModal() == .OK, let u = p.url { customFolder = u.path }
                        }
                    }
                }
                Toggle("Reveal results in Finder", isOn: $reveal)
            }
            Section("Quality") {
                HStack {
                    Text("Lossy image quality")
                    Slider(value: $quality, in: 0.3...1.0, step: 0.05)
                    Text("\(Int(quality * 100))%").monospacedDigit().frame(width: 40)
                }
            }
            Section("Engines") {
                LabeledContent("Built-in (offline)", value: "ImageIO · AVFoundation · PDFKit · Vision · afconvert · bsdtar")
                LabeledContent("ffmpeg", value: Tools.ffmpeg ?? "Not found – install with Homebrew for MP3, OGG, WebM, MKV, AVI")
                LabeledContent("cwebp", value: Tools.cwebp ?? "Not found – install webp for WebP export")
                LabeledContent("Available", value: "\(ActionRegistry.all.count) actions · \(ActionRegistry.conversionCount.formatted()) combinations")
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 520)
    }
}
