import SwiftUI
import AppKit
import CodevisorUI

/// A sheet for choosing an SF Symbol icon for a project. Presents a searchable
/// grid of system symbols; selecting one applies it immediately.
struct IconPickerView: View {
    let currentSymbol: String
    let onSelect: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @State private var query = ""
    @State private var library: SFSymbolLibrary.Library?

    private let columns = [GridItem(.adaptive(minimum: 44), spacing: 8)]

    private func filtered(in library: SFSymbolLibrary.Library) -> [String] {
        let tokens = query
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .split(whereSeparator: { $0 == " " || $0 == "." || $0 == "_" || $0 == "-" })
            .map(String.init)
        guard !tokens.isEmpty else { return library.symbols }
        return library.entries.compactMap { entry in
            tokens.allSatisfy { token in
                entry.haystack.contains { $0.contains(token) }
            } ? entry.symbol : nil
        }
    }

    private func typedSymbol(filtered: [String]) -> String? {
        let symbol = query
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: ".")
        guard !symbol.isEmpty,
              symbol.contains(".fill"),
              !filtered.contains(symbol),
              SFSymbolLibrary.isAvailable(symbol)
        else { return nil }
        return symbol
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Choose an icon")
                    .font(.headline)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)

            Divider()

            Group {
                if let library {
                    symbolGrid(library)
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(height: 300)

            Divider()

            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search icons", text: $query)
                    .textFieldStyle(.plain)
            }
            .padding(12)
        }
        .frame(width: 360)
        .task {
            library = await SFSymbolLibrary.loaded()
        }
    }

    private func symbolGrid(_ library: SFSymbolLibrary.Library) -> some View {
        let filtered = filtered(in: library)
        let typedSymbol = typedSymbol(filtered: filtered)
        return ScrollView {
            LazyVGrid(columns: columns, spacing: 8) {
                if let typedSymbol {
                    symbolButton(typedSymbol)
                }
                ForEach(filtered, id: \.self) { symbol in
                    symbolButton(symbol)
                }
            }
            .padding(16)
        }
    }

    private func symbolButton(_ symbol: String) -> some View {
        Button {
            onSelect(symbol)
            dismiss()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 18))
                .frame(width: 44, height: 44)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(symbol == currentSymbol ? AnyShapeStyle(.tint.opacity(0.25)) : theme.cardBackground)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(.tint, lineWidth: symbol == currentSymbol ? 2 : 0)
                )
        }
        .buttonStyle(.plain)
        .help(symbol)
        .accessibilityLabel(symbol.replacingOccurrences(of: ".", with: " "))
    }
}

private nonisolated enum SFSymbolLibrary {
    /// The symbol list plus a precomputed lowercased search index, built once
    /// off the main thread. Parsing the multi-MB CoreGlyphs plists and probing
    /// symbol availability for thousands of names is far too slow for `body`.
    nonisolated struct Library: Sendable {
        /// Curated symbols in display order.
        let symbols: [String]
        /// One entry per symbol, in the same order, with the lowercased
        /// search terms (name + system search terms) precomputed so
        /// per-keystroke filtering allocates nothing beyond the result array.
        let entries: [(symbol: String, haystack: [String])]
    }

    /// Memoized background load: kicked off at most once, shared by every
    /// subsequent picker presentation.
    private static let loadTask = Task.detached(priority: .userInitiated) {
        buildLibrary()
    }

    static func loaded() async -> Library {
        await loadTask.value
    }

    private static func buildLibrary() -> Library {
        let loaded = loadSymbolOrder() ?? loadSymbolAvailability()
        var seen = Set<String>()
        // The sidebar sticks to filled icons, so only offer filled variants.
        let symbols = (loaded ?? fallbackSymbols).filter { symbol in
            symbol.contains(".fill") && seen.insert(symbol).inserted && isAvailable(symbol)
        }
        let searchTerms = loadSearchTerms() ?? [:]
        let entries = symbols.map { symbol in
            (symbol: symbol, haystack: ([symbol] + (searchTerms[symbol] ?? [])).map { $0.lowercased() })
        }
        return Library(symbols: symbols, entries: entries)
    }

    static func isAvailable(_ symbol: String) -> Bool {
        NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil
    }

    private static func loadSymbolOrder() -> [String]? {
        loadPlistResource("symbol_order") as? [String]
    }

    private static func loadSymbolAvailability() -> [String]? {
        guard let plist = loadPlistResource("name_availability") as? [String: Any],
              let symbols = plist["symbols"] as? [String: Any]
        else { return nil }
        return symbols.keys.sorted()
    }

    private static func loadSearchTerms() -> [String: [String]]? {
        loadPlistResource("symbol_search") as? [String: [String]]
    }

    private static func loadPlistResource(_ name: String) -> Any? {
        guard let bundle = Bundle(url: URL(fileURLWithPath: "/System/Library/CoreServices/CoreGlyphs.bundle")),
              let url = bundle.url(forResource: name, withExtension: "plist"),
              let data = try? Data(contentsOf: url)
        else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)
    }

    private static let fallbackSymbols: [String] = [
        "folder", "folder.fill", "folder.badge.gearshape", "tray.full", "archivebox",
        "doc", "doc.text", "doc.richtext", "book", "books.vertical", "newspaper",
        "hammer", "wrench.and.screwdriver", "screwdriver", "gearshape", "gearshape.2",
        "cpu", "memorychip", "server.rack", "externaldrive", "internaldrive",
        "globe", "network", "antenna.radiowaves.left.and.right", "wifi", "cloud",
        "terminal", "curlybraces", "chevron.left.forwardslash.chevron.right", "command", "keyboard",
        "paintbrush", "paintpalette", "pencil.and.ruler", "ruler", "scribble",
        "sparkles", "sparkle", "star", "star.fill", "bolt", "bolt.fill", "flame", "flame.fill",
        "heart", "heart.fill", "leaf", "tree", "ant", "ladybug", "tortoise", "hare", "bird",
        "cube", "cube.box", "shippingbox", "cylinder", "puzzlepiece", "puzzlepiece.extension",
        "app", "app.badge", "square.grid.2x2", "square.stack.3d.up", "circle.grid.cross",
        "music.note", "headphones", "gamecontroller", "film", "camera", "photo",
        "cart", "bag", "creditcard", "dollarsign.circle", "chart.bar", "chart.pie", "chart.line.uptrend.xyaxis",
        "person", "person.2", "person.3", "building.2", "house", "graduationcap", "briefcase",
        "flask", "atom", "function", "sum", "x.squareroot", "brain", "lightbulb",
        "map", "location", "flag", "tag", "bookmark", "paperclip", "link", "lock", "key", "shield"
    ]
}

#Preview {
    IconPickerView(currentSymbol: "folder.fill") { _ in }
}
