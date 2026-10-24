import AppKit
import ConverterKit
import SwiftUI

/// `UniversalConverter --snapshot <dir> <files…>` renders the main window and drop panel to PNGs
/// (used to check the UI without screen-recording access).
@MainActor
enum Snapshot {
    static func runIfRequested() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return }
        let dir = URL(fileURLWithPath: args[i + 1])
        let files = args.dropFirst(i + 2).map { URL(fileURLWithPath: $0) }

        AppModel.shared.selection = []
        save(MainView().frame(width: 980, height: 640), size: NSSize(width: 980, height: 640), to: dir.appendingPathComponent("main-empty.png"))
        AppModel.shared.selection = files
        if let a = ActionRegistry.action(id: "image.to.png"), a.canHandle(files) { AppModel.shared.run(a, on: files) }
        save(MainView().frame(width: 980, height: 640), size: NSSize(width: 980, height: 640), to: dir.appendingPathComponent("main-files.png"))
        let state = DropPanelController.shared.state
        state.urls = files
        state.actions = AppModel.shared.actions(for: files)
        state.category = DropPanelController.preferredCategory(for: files, among: state.categories)
        let probe = NSHostingView(rootView: PanelView(state: state, close: {}).frame(width: 660))
        save(PanelView(state: state, close: {}).frame(width: 660), size: NSSize(width: 660, height: probe.fittingSize.height),
             to: dir.appendingPathComponent("panel.png"))
        exit(0)
    }

    static func save<V: View>(_ view: V, size: NSSize, to url: URL) {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        window.contentView = host
        window.orderFrontRegardless()
        for _ in 0..<5 { RunLoop.main.run(until: Date().addingTimeInterval(0.2)); host.layoutSubtreeIfNeeded() }
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        window.orderOut(nil)
    }
}
