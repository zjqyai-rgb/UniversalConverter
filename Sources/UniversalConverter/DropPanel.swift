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
    enum Phase { case choosing, working(Job) }
    @Published var urls: [URL] = []
    @Published var actions: [FileAction] = []
    @Published var category: ActionCategory = .image
    @Published var phase: Phase = .choosing

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
    private let width: CGFloat = 660

    private func makePanel() -> FloatingPanel {
        let p = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: 300),
                              styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .popUpMenu
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.isMovableByWindowBackground = true
        let host = NSHostingView(rootView: PanelView(state: state, close: { [weak self] in self?.hide() }))
        host.autoresizingMask = [.width, .height]
        p.contentView = host
        return p
    }

    func show(for urls: [URL], near point: NSPoint) {
        hideWork?.cancel()
        if case .working(let job) = state.phase, job.isRunning { return } // don't interrupt a running job
        state.urls = urls
        state.actions = AppModel.shared.actions(for: urls)
        state.category = Self.preferredCategory(for: urls, among: state.categories)
        state.phase = .choosing

        let height = idealHeight()
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        let vis = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var x = point.x - width / 2
        var y = point.y + 28 // panel sits just above the cursor
        if y + height > vis.maxY { y = point.y - height - 28 } // or below if there's no room
        x = min(max(x, vis.minX + 8), vis.maxX - width - 8)
        y = min(max(y, vis.minY + 8), vis.maxY - height - 8)
        panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.12; panel.animator().alphaValue = 1 }
    }

    /// Tallest layout across categories so the panel doesn't jump while you hover tabs.
    private func idealHeight() -> CGFloat {
        let original = state.category
        var best: CGFloat = 200
        for c in state.categories {
            state.category = c
            let probe = NSHostingView(rootView: PanelView(state: state, close: {}).frame(width: width))
            best = max(best, probe.fittingSize.height)
        }
        state.category = original
        let maxH = (NSScreen.main?.visibleFrame.height ?? 900) * 0.8
        return min(best, maxH)
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
            guard let self, case .choosing = self.state.phase else { return }
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
                self.state.phase = .choosing
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
        Group {
            switch state.phase {
            case .choosing: chooser
            case .working(let job): JobStatusView(job: job, close: close)
            }
        }
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
