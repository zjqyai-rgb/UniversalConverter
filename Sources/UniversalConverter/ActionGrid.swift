import ConverterKit
import SwiftUI
import UniformTypeIdentifiers

/// Grid of action tiles grouped by category. In `.drop` mode each tile is a drop target;
/// in `.click` mode tiles are buttons that act on already-chosen files.
struct ActionGrid: View {
    enum Mode {
        case click((FileAction) -> Void)
        case drop(([URL], FileAction) -> Void)
    }

    let actions: [FileAction]
    let mode: Mode
    var compact = false
    var favorites: [String] = []

    private var groups: [(String, Color, String, [FileAction])] {
        var result: [(String, Color, String, [FileAction])] = []
        let favs = actions.filter { favorites.contains($0.id) }
        if !favs.isEmpty { result.append(("Favorites", .yellow, "star.fill", favs)) }
        for cat in ActionCategory.allCases {
            let items = actions.filter { $0.category == cat && !favorites.contains($0.id) }
            if !items.isEmpty { result.append((cat.rawValue, cat.color, cat.symbol, items)) }
        }
        return result
    }

    var body: some View {
        let tile: CGFloat = compact ? 76 : 92
        VStack(alignment: .leading, spacing: compact ? 8 : 14) {
            ForEach(groups, id: \.0) { name, color, symbol, items in
                VStack(alignment: .leading, spacing: 6) {
                    Label(name, systemImage: symbol)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(color)
                    if compact {
                        // Eager rows: LazyVGrid under-reports its fitting height, which clipped the panel.
                        let cols = 7
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(stride(from: 0, to: items.count, by: cols)), id: \.self) { start in
                                HStack(spacing: 6) {
                                    ForEach(items[start..<min(start + cols, items.count)]) { action in
                                        ActionTile(action: action, mode: mode, compact: compact, tint: color)
                                    }
                                    ForEach(0..<(cols - min(cols, items.count - start)), id: \.self) { _ in
                                        Color.clear.frame(maxWidth: .infinity, minHeight: 1)
                                    }
                                }
                            }
                        }
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: tile, maximum: tile + 20), spacing: 6)], alignment: .leading, spacing: 6) {
                            ForEach(items) { action in
                                ActionTile(action: action, mode: mode, compact: compact, tint: color)
                            }
                        }
                    }
                }
            }
        }
    }
}

struct ActionTile: View {
    let action: FileAction
    let mode: ActionGrid.Mode
    let compact: Bool
    let tint: Color
    @Local private var hovering = false
    @ObservedObject private var model = AppModel.shared

    var body: some View {
        let content = VStack(spacing: 4) {
            Image(systemName: action.symbol)
                .font(.system(size: compact ? 17 : 20, weight: .medium))
                .frame(height: compact ? 20 : 24)
            Text(action.title)
                .font(.system(size: compact ? 10.5 : 11.5, weight: .semibold))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.8)
        }
        .foregroundStyle(hovering ? Color.white : Color.primary)
        .frame(maxWidth: .infinity, minHeight: compact ? 56 : 66)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(hovering ? tint : tint.opacity(0.13))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(tint.opacity(hovering ? 0.9 : 0.25), lineWidth: hovering ? 2 : 1)
        )
        .overlay(alignment: .topTrailing) {
            if model.favorites.contains(action.id) {
                Image(systemName: "star.fill").font(.system(size: 8)).foregroundStyle(.yellow).padding(5)
            }
        }
        .scaleEffect(hovering ? 1.07 : 1)
        .animation(.spring(response: 0.2, dampingFraction: 0.7), value: hovering)
        .help(action.detail)
        .contentShape(Rectangle())

        switch mode {
        case .click(let perform):
            content
                .onHover { hovering = $0 }
                .onTapGesture { perform(action) }
                .contextMenu {
                    Button(model.favorites.contains(action.id) ? "Remove from Shift-Drag Ring" : "Add to Shift-Drag Ring") {
                        model.toggleFavorite(action.id)
                    }
                }
        case .drop(let perform):
            content.onDrop(of: [.fileURL], isTargeted: $hovering) { providers in
                loadURLs(providers) { urls in if !urls.isEmpty { perform(urls, action) } }
                return true
            }
        }
    }
}

func loadURLs(_ providers: [NSItemProvider], completion: @escaping @MainActor ([URL]) -> Void) {
    let group = DispatchGroup()
    let lock = NSLock()
    var urls: [(Int, URL)] = []
    for (i, p) in providers.enumerated() where p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
        group.enter()
        p.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            var url: URL?
            if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
            else if let u = item as? URL { url = u }
            if let url { lock.lock(); urls.append((i, url.standardizedFileURL)); lock.unlock() }
            group.leave()
        }
    }
    group.notify(queue: .main) {
        let sorted = urls.sorted { $0.0 < $1.0 }.map(\.1)
        MainActor.assumeIsolated { completion(sorted) }
    }
}
