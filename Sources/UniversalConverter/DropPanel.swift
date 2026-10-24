import AppKit
import ConverterKit
import SwiftUI

// MARK: - Global Shift-drag detection

/// Watches system-wide mouse drags. When a file drag is in progress and Shift is held,
/// the floating format panel appears near the cursor.
@MainActor
final class DragMonitor {
    static let shared = DragMonitor()
    private var monitors: [Any] = []
    private var changeCountAtMouseDown = NSPasteboard(name: .drag).changeCount
    private var panelShownForThisDrag = false

    func start() {
        guard monitors.isEmpty else { return }
        let handlers: [(NSEvent.EventTypeMask, (DragMonitor) -> Void)] = [
            (.leftMouseDown, { $0.mouseDown() }),
            (.leftMouseDragged, { $0.mouseDragged() }),
            (.leftMouseUp, { $0.mouseUp() }),
            (.flagsChanged, { $0.mouseDragged() }),
        ]
        for (mask, handler) in handlers {
            if let m = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
                MainActor.assumeIsolated { if let self { handler(self) } }
            }) { monitors.append(m) }
        }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp, handler: { [weak self] e in
            MainActor.assumeIsolated { self?.mouseUp() }
            return e
        }) { monitors.append(m) }
    }

    private func mouseDown() {
        changeCountAtMouseDown = NSPasteboard(name: .drag).changeCount
        panelShownForThisDrag = false
    }

    private func mouseDragged() {
        guard UserDefaults.standard.bool(forKey: Prefs.shiftDrag), !panelShownForThisDrag,
              NSEvent.pressedMouseButtons & 1 == 1,
              NSEvent.modifierFlags.contains(.shift) else { return }
        let pb = NSPasteboard(name: .drag)
        guard pb.changeCount != changeCountAtMouseDown else { return }
        let urls = (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        guard !urls.isEmpty else { return }
        panelShownForThisDrag = true
        DropPanelController.shared.show(for: urls, near: NSEvent.mouseLocation)
    }

    private func mouseUp() {
        if panelShownForThisDrag { DropPanelController.shared.dragEnded() }
        panelShownForThisDrag = false
    }
}

// MARK: - Panel

@MainActor
final class PanelState: ObservableObject {
    enum Phase { case ring, grid, working(Job) }
    @Published var urls: [URL] = []
    @Published var actions: [FileAction] = []
    @Published var ringActions: [FileAction] = []
    @Published var usingDefaults = false
    @Published var category: ActionCategory = .image
    @Published var phase: Phase = .ring

    var isChoosing: Bool { if case .working = phase { return false }; return true }
    var categories: [ActionCategory] {
        ActionCategory.allCases.filter { c in actions.contains { $0.category == c } }
    }
    var visibleActions: [FileAction] {
        let favs = AppModel.shared.favorites
        return actions.filter { $0.category == category || favs.contains($0.id) }
    }
}

final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class DropPanelController {
    static let shared = DropPanelController()
    let state = PanelState()
    private lazy var panel: FloatingPanel = makePanel()
    private var hideWork: DispatchWorkItem?
    private var anchor = NSPoint.zero
    let gridWidth: CGFloat = 660

    private func makePanel() -> FloatingPanel {
        let p = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: gridWidth, height: 300),
                              styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .popUpMenu
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false // the SwiftUI views draw their own shadow so the ring stays round
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: PanelView(state: state, close: { [weak self] in self?.hide() }))
        host.autoresizingMask = [.width, .height]
        p.contentView = host
        return p
    }

    /// Shows the favorites ring centered on the cursor.
    func show(for urls: [URL], near point: NSPoint) {
        hideWork?.cancel()
        if case .working(let job) = state.phase, job.isRunning { return } // don't interrupt a running job
        anchor = point
        state.urls = urls
        state.actions = AppModel.shared.actions(for: urls)
        let (ring, defaults) = Self.ringActions(for: urls, available: state.actions)
        state.ringActions = ring
        state.usingDefaults = defaults
        state.category = Self.preferredCategory(for: urls, among: state.categories)
        state.phase = .ring

        let side = RingView.diameter(for: ring.count + 1)
        place(NSRect(x: point.x - side / 2, y: point.y - side / 2, width: side, height: side), animated: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.12; panel.animator().alphaValue = 1 }
    }

    /// Favorites that apply to these files; falls back to sensible picks for the file type.
    static func ringActions(for urls: [URL], available: [FileAction]) -> ([FileAction], Bool) {
        let ids = Set(available.map(\.id))
        let favs = AppModel.shared.favorites.filter(ids.contains)
        if !favs.isEmpty {
            return (favs.prefix(12).compactMap { id in available.first { $0.id == id } }, false)
        }
        let picks = defaultRing[FileKind.of(urls[0])] ?? []
        var list = picks.compactMap { id in available.first { $0.id == id } }
        for a in available where list.count < 6 && !list.contains(where: { $0.id == a.id }) { list.append(a) }
        return (Array(list.prefix(8)), true)
    }

    static let defaultRing: [FileKind: [String]] = {
        let doc = ["doc.to.pdf", "doc.to.docx", "doc.to.html", "doc.to.md", "doc.to.txt", "doc.speak"]
        let data = ["data.json", "data.yaml", "data.csv", "data.plist", "data.pretty", "data.htmltable"]
        return [
            .image: ["image.to.png", "image.to.jpg", "image.to.heic", "image.to.webp", "image.pdf", "image.compress", "image.resize50", "image.removebg"],
            .svg: ["image.to.png", "image.to.jpg", "image.pdf", "image.icns"],
            .video: ["video.mp4", "video.hevc", "video.gif", "audio.m4a", "audio.mp3", "video.720", "video.frame"],
            .audio: ["audio.mp3", "audio.m4a", "audio.wav", "audio.flac", "audio.alac", "audio.voice"],
            .pdf: ["pdf.to.png", "pdf.compress", "pdf.merge", "doc.to.docx", "doc.to.txt", "util.ocr"],
            .document: doc, .markdown: doc, .html: doc, .plainText: doc,
            .json: data, .yaml: data, .plist: data, .csv: data, .tsv: data,
            .xml: ["data.xmlpretty", "data.validate", "archive.zip"],
            .archive: ["archive.extract", "archive.list", "util.sha256"],
            .folder: ["archive.zip", "archive.dmg", "archive.txz", "util.copypath"],
            .other: ["archive.zip", "util.sha256", "util.copypath", "util.base64"],
        ]
    }()

    /// Spring-loaded "More": switch from the ring to the full grid near the cursor.
    func expandToGrid() {
        guard case .ring = state.phase else { return }
        state.phase = .grid
        let height = gridHeight()
        var rect = NSRect(x: anchor.x - gridWidth / 2, y: anchor.y - height / 2, width: gridWidth, height: height)
        if let vis = screen(for: anchor)?.visibleFrame, rect.height > vis.height - 16 { rect.size.height = vis.height - 16 }
        place(rect, animated: true)
    }

    /// Tallest layout across categories so the panel doesn't jump while you hover tabs.
    private func gridHeight() -> CGFloat {
        let original = state.category
        var best: CGFloat = 200
        for c in state.categories {
            state.category = c
            let probe = NSHostingView(rootView: PanelView(state: state, close: {}).frame(width: gridWidth))
            best = max(best, probe.fittingSize.height)
        }
        state.category = original
        return best
    }

    private func screen(for point: NSPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
    }

    /// Clamp to the visible screen area and apply.
    private func place(_ rect: NSRect, animated: Bool) {
        var r = rect
        if let vis = screen(for: anchor)?.visibleFrame {
            r.origin.x = min(max(r.minX, vis.minX + 4), vis.maxX - r.width - 4)
            r.origin.y = min(max(r.minY, vis.minY + 4), vis.maxY - r.height - 4)
        }
        panel.setFrame(r, display: true, animate: animated)
    }

    static func preferredCategory(for urls: [URL], among cats: [ActionCategory]) -> ActionCategory {
        let kind = FileKind.of(urls[0])
        let wanted: ActionCategory
        switch kind {
        case .image, .svg: wanted = .image
        case .video: wanted = .video
        case .audio: wanted = .audio
        case .pdf: wanted = .pdf
        case .document, .markdown, .html, .plainText: wanted = .document
        case .json, .plist, .csv, .tsv, .yaml, .xml: wanted = .data
        case .archive, .folder: wanted = .archive
        case .other: wanted = .utility
        }
        return cats.contains(wanted) ? wanted : (cats.first ?? .utility)
    }

    func perform(_ action: FileAction, on urls: [URL]) {
        hideWork?.cancel()
        let job = AppModel.shared.run(action, on: urls)
        state.phase = .working(job)
        let w: CGFloat = 440, h: CGFloat = 150
        place(NSRect(x: anchor.x - w / 2, y: anchor.y - h / 2, width: w, height: h), animated: false)
        scheduleAutoHide(after: job)
    }

    private func scheduleAutoHide(after job: Job) {
        Task { @MainActor [weak self] in
            while job.isRunning { try? await Task.sleep(nanoseconds: 150_000_000) }
            let delay: Double = job.failure == nil ? 2.5 : 6
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            // Stay open while the pointer is over the panel.
            while let self, self.panel.isVisible, self.panel.frame.contains(NSEvent.mouseLocation) {
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
            guard let self, case .working(let current) = self.state.phase, current === job else { return }
            self.hide()
        }
    }

    func dragEnded() {
        // Give the drop handler a moment to fire before deciding the drag was cancelled.
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.state.isChoosing else { return }
            self.hide()
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    func hide() {
        hideWork?.cancel()
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.15; panel.animator().alphaValue = 0 }) {
            MainActor.assumeIsolated {
                self.panel.orderOut(nil)
                self.state.phase = .ring
            }
        }
    }
}

// MARK: - Panel views

struct PanelView: View {
    @ObservedObject var state: PanelState
    @ObservedObject private var model = AppModel.shared
    let close: () -> Void

    var body: some View {
        switch state.phase {
        case .ring:
            RingView(state: state)
        case .grid:
            card { chooser }
        case .working(let job):
            card { JobStatusView(job: job, close: close) }
                .frame(maxHeight: .infinity, alignment: .center)
        }
    }

    private func card<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        content()
            .padding(14)
            .background(VisualEffect().clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous)))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.15)))
    }

    private var chooser: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                FileStack(urls: state.urls).frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text(state.urls.count == 1 ? state.urls[0].lastPathComponent : "\(state.urls.count) files")
                        .font(.headline).lineLimit(1).truncationMode(.middle)
                    Text("Drop onto a format · hover a tab to switch")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: close) { Image(systemName: "xmark.circle.fill").font(.title3) }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
            }
            if state.actions.isEmpty {
                Text("No conversions for this combination of files.")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 80)
            } else {
                HStack(spacing: 6) {
                    ForEach(state.categories, id: \.self) { cat in
                        CategoryTab(category: cat, selected: state.category == cat) { state.category = cat }
                    }
                }
                ActionGrid(actions: state.visibleActions, mode: .drop { urls, action in
                    DropPanelController.shared.perform(action, on: urls)
                }, compact: true, favorites: model.favorites)
                .id(state.category)
            }
        }
    }
}

/// Favorite formats arranged in a circle around the dragged file.
struct RingView: View {
    @ObservedObject var state: PanelState
    static let bubble: CGFloat = 66

    /// Radius that keeps `count` bubbles from overlapping.
    static func radius(for count: Int) -> CGFloat {
        max(78, CGFloat(count) * (bubble + 8) / (2 * .pi))
    }
    static func diameter(for count: Int) -> CGFloat { (radius(for: count) + bubble / 2 + 18) * 2 }

    var body: some View {
        let items = state.ringActions.map { RingItem.action($0) } + [.more]
        let r = Self.radius(for: items.count)
        let d = Self.diameter(for: items.count)
        ZStack {
            // Round translucent backdrop.
            VisualEffect()
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.18)))
                .frame(width: d - 8, height: d - 8)
                .shadow(color: .black.opacity(0.35), radius: 10, y: 3)
            // Hub: the file being dragged.
            VStack(spacing: 2) {
                FileStack(urls: state.urls).frame(width: 34, height: 34)
                Text(state.urls.count == 1 ? state.urls[0].pathExtension.uppercased() : "\(state.urls.count) files")
                    .font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                if state.usingDefaults {
                    Text("Suggested").font(.system(size: 8)).foregroundStyle(.tertiary)
                }
            }
            ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                let angle = -Double.pi / 2 + 2 * Double.pi * Double(i) / Double(items.count)
                RingBubble(item: item)
                    .offset(x: CGFloat(cos(angle)) * r, y: CGFloat(sin(angle)) * r)
            }
        }
        .frame(width: d, height: d)
    }
}

enum RingItem {
    case action(FileAction)
    case more
}

struct RingBubble: View {
    let item: RingItem
    @Local private var targeted = false

    var body: some View {
        let (symbol, title, color): (String, String, Color) = {
            switch item {
            case .action(let a): return (a.symbol, a.title, a.category.color)
            case .more: return ("ellipsis", "More", .gray)
            }
        }()
        VStack(spacing: 2) {
            Image(systemName: symbol).font(.system(size: 18, weight: .semibold))
            Text(title).font(.system(size: 9.5, weight: .bold)).lineLimit(1).minimumScaleFactor(0.6)
        }
        .padding(.horizontal, 6)
        .foregroundStyle(targeted ? .white : .primary)
        .frame(width: RingView.bubble, height: RingView.bubble)
        .background(Circle().fill(targeted ? color : color.opacity(0.28)))
        .overlay(Circle().strokeBorder(color.opacity(targeted ? 1 : 0.55), lineWidth: targeted ? 2.5 : 1.2))
        .scaleEffect(targeted ? 1.22 : 1)
        .animation(.spring(response: 0.22, dampingFraction: 0.65), value: targeted)
        .help({ if case .action(let a) = item { return a.detail }; return "All formats" }())
        .contentShape(Circle())
        .onTapGesture { if case .more = item { DropPanelController.shared.expandToGrid() } }
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            switch item {
            case .action(let action):
                loadURLs(providers) { urls in if !urls.isEmpty { DropPanelController.shared.perform(action, on: urls) } }
                return true
            case .more:
                return false
            }
        }
        .onChange(of: targeted) { _, now in
            // Spring-load "More": hovering it briefly opens every format.
            guard now, case .more = item else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                if targeted { DropPanelController.shared.expandToGrid() }
            }
        }
    }
}

/// Category chip; hovering a drag over it switches categories (spring-loaded).
struct CategoryTab: View {
    let category: ActionCategory
    let selected: Bool
    let select: () -> Void
    @Local private var targeted = false

    var body: some View {
        Label(category.rawValue, systemImage: category.symbol)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Capsule().fill(selected ? category.color : category.color.opacity(0.12)))
            .foregroundStyle(selected ? .white : .primary)
            .contentShape(Capsule())
            .onTapGesture(perform: select)
            .onDrop(of: [.fileURL], isTargeted: $targeted) { _ in false }
            .onChange(of: targeted) { _, now in if now { select() } }
    }
}

struct JobStatusView: View {
    @ObservedObject var job: Job
    let close: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill(color.opacity(0.15)).frame(width: 44, height: 44)
                if job.isRunning {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: job.failure == nil ? "checkmark" : "exclamationmark.triangle.fill")
                        .font(.title3.bold()).foregroundStyle(color)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(job.title).font(.headline).lineLimit(1).truncationMode(.middle)
                if job.isRunning {
                    ProgressView(value: job.progress).frame(maxWidth: .infinity)
                } else if let f = job.failure {
                    Text(f).font(.callout).foregroundStyle(.secondary).lineLimit(4).textSelection(.enabled)
                } else {
                    JobResultSummary(job: job)
                }
            }
            Spacer(minLength: 0)
            Button(action: close) { Image(systemName: "xmark.circle.fill").font(.title3) }
                .buttonStyle(.plain).foregroundStyle(.secondary)
        }
    }

    var color: Color { job.failure == nil ? (job.isRunning ? .accentColor : .green) : .orange }
}

struct JobResultSummary: View {
    @ObservedObject var job: Job
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !job.output.files.isEmpty {
                Text(job.output.files.count == 1 ? "Saved \(job.output.files[0].lastPathComponent)" : "Saved \(job.output.files.count) items")
                    .font(.callout).lineLimit(1).truncationMode(.middle)
            }
            if let m = job.output.message {
                Text(m).font(.callout.monospaced()).lineLimit(5).textSelection(.enabled)
            }
            HStack {
                if !job.output.files.isEmpty {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(job.output.files) }
                    if job.output.files.count == 1 {
                        Button("Open") { NSWorkspace.shared.open(job.output.files[0]) }
                    }
                }
                if job.output.clipboard != nil {
                    Label("Copied to clipboard", systemImage: "doc.on.clipboard").font(.caption).foregroundStyle(.secondary)
                }
            }
            .controlSize(.small)
        }
    }
}

struct FileStack: View {
    let urls: [URL]
    var body: some View {
        ZStack {
            ForEach(Array(urls.prefix(3).enumerated().reversed()), id: \.offset) { i, url in
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable().scaledToFit()
                    .rotationEffect(.degrees(Double(i) * -6))
                    .offset(x: CGFloat(i) * 3, y: CGFloat(i) * -2)
            }
        }
    }
}

struct VisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}
