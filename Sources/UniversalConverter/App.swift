import AppKit
import ConverterKit
import SwiftUI

@main
struct UniversalConverterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var model = AppModel.shared

    var body: some Scene {
        Window("Universal Converter", id: "main") {
            MainView()
                .frame(minWidth: 820, minHeight: 520)
        }
        .defaultSize(width: 980, height: 640)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        Settings { SettingsView() }

        MenuBarExtra {
            MenuBarContent()
        } label: {
            Image(systemName: model.jobs.contains(where: \.isRunning) ? "arrow.triangle.2.circlepath.circle.fill" : "arrow.triangle.2.circlepath")
        }
    }
}

struct MenuBarContent: View {
    @ObservedObject private var model = AppModel.shared
    @AppStorage(Prefs.shiftDrag) private var shiftDrag = true
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Open Universal Converter") { showMain() }
        Toggle("Shift-Drag Panel", isOn: $shiftDrag)
        Divider()
        if model.jobs.isEmpty {
            Text("No recent conversions")
        } else {
            ForEach(model.jobs.prefix(6)) { job in
                Button((job.isRunning ? "⏳ " : job.failure == nil ? "✓ " : "⚠︎ ") + job.title) {
                    if !job.output.files.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(job.output.files) }
                }
            }
        }
        Divider()
        SettingsLink { Text("Settings…") }.keyboardShortcut(",")
        Button("Quit") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }

    private func showMain() {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        Prefs.register()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            Snapshot.runIfRequested()
            DragMonitor.shared.start()
        }
        NSApp.servicesProvider = self
    }

    /// Files dropped on the Dock icon or opened with the app.
    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            AppModel.shared.selection = urls.map(\.standardizedFileURL)
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first { $0.identifier?.rawValue == "main" }?.makeKeyAndOrderFront(nil)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { NSApp.windows.first { $0.identifier?.rawValue == "main" }?.makeKeyAndOrderFront(nil) }
        return true
    }

    /// Finder ▸ Services ▸ "Convert with Universal Converter".
    @objc func convertFiles(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = (pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        guard !urls.isEmpty else { return }
        application(NSApp, open: urls)
    }
}
