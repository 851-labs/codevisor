import SwiftUI

/// A sheet for choosing an SF Symbol icon for a workspace. Presents a searchable
/// grid of common project icons; selecting one applies it immediately.
struct IconPickerView: View {
    let currentSymbol: String
    let onSelect: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private let columns = [GridItem(.adaptive(minimum: 44), spacing: 8)]

    private var filtered: [String] {
        let trimmed = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty else { return Self.symbols }
        return Self.symbols.filter { $0.contains(trimmed) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Choose an Icon")
                    .font(.headline)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)

            Divider()

            ScrollView {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(filtered, id: \.self) { symbol in
                        Button {
                            onSelect(symbol)
                            dismiss()
                        } label: {
                            Image(systemName: symbol)
                                .font(.system(size: 18))
                                .frame(width: 44, height: 44)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(symbol == currentSymbol ? AnyShapeStyle(.tint.opacity(0.25)) : AnyShapeStyle(.quaternary.opacity(0.4)))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .strokeBorder(.tint, lineWidth: symbol == currentSymbol ? 2 : 0)
                                )
                        }
                        .buttonStyle(.plain)
                        .help(symbol)
                    }
                }
                .padding(16)
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
    }

    /// A curated set of SF Symbols suitable for project folders.
    static let symbols: [String] = [
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
    IconPickerView(currentSymbol: "folder") { _ in }
}
