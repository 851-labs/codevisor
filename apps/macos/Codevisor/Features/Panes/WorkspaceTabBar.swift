import SwiftUI
import UniformTypeIdentifiers
import CodevisorCore

/// The workspace's browser-style ownership layer rendered in the same
/// native capsule strip used by the previous pane tabs. Each item now owns
/// a complete split layout instead of belonging to one split leaf.
struct WorkspaceTabBar: View {
    let tabs: [WorkspaceTab]
    let selectedTabId: UUID
    let title: (WorkspaceTab) -> String
    let descriptor: (WorkspaceTab) -> PaneDescriptorState?
    let onSelect: (UUID) -> Void
    let onClose: (UUID) -> Void
    let onMove: (UUID, UUID) -> Void
    let onRename: (UUID, String?) -> Void
    let onNew: () -> Void

    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    @State private var renamingTabId: UUID?
    @State private var renameText = ""

    private let barHeight: CGFloat = 28
    private let minimumTabWidth: CGFloat = 100
    private let addButtonDiameter: CGFloat = 26

    var body: some View {
        GeometryReader { geometry in
            let available = max(
                geometry.size.width - addButtonDiameter - 12,
                minimumTabWidth
            )
            let fitted = available / CGFloat(max(tabs.count, 1))
            let tabWidth = max(minimumTabWidth, fitted)
            let stripWidth = max(available, tabWidth * CGFloat(tabs.count))

            HStack(spacing: 4) {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal) {
                        HStack(spacing: 0) {
                            ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
                                let pane = descriptor(tab)
                                PaneTab(
                                    name: title(tab),
                                    kind: pane?.kind ?? .newTab,
                                    isAgentOwned: pane?.attachOnly ?? false,
                                    isSelected: tab.id == selectedTabId,
                                    isDragging: false,
                                    width: tabWidth,
                                    canClose: true,
                                    showsTrailingSeparator: index < tabs.count - 1
                                        && tab.id != selectedTabId
                                        && tabs[index + 1].id != selectedTabId,
                                    shortcutHint: nil,
                                    onSelect: { onSelect(tab.id) },
                                    onClose: { onClose(tab.id) }
                                )
                                .id(tab.id)
                                .onDrag {
                                    NSItemProvider(object: tab.id.uuidString as NSString)
                                }
                                .onDrop(
                                    of: [.plainText],
                                    delegate: WorkspaceTabDropDelegate(
                                        targetId: tab.id,
                                        onMove: onMove
                                    )
                                )
                                .contextMenu {
                                    Button {
                                        renameText = title(tab)
                                        renamingTabId = tab.id
                                    } label: {
                                        Label("Rename", systemImage: "pencil")
                                            .labelStyle(.titleAndIcon)
                                    }
                                }
                            }
                        }
                        .frame(width: stripWidth, height: barHeight, alignment: .leading)
                        .background(
                            Capsule()
                                .fill(colorScheme == .dark
                                    ? Color.white.opacity(0.12)
                                    : Color.black.opacity(0.06))
                        )
                    }
                    .scrollIndicators(.hidden)
                    .onChange(of: selectedTabId, initial: true) { _, selected in
                        withAnimation(PaneGroupBar.tabMotion) {
                            proxy.scrollTo(selected, anchor: .center)
                        }
                    }
                }
                .frame(width: available, height: barHeight)

                Button(action: onNew) {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(theme.textPrimary)
                        .frame(width: addButtonDiameter, height: addButtonDiameter)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: Circle())
                .help("New tab (⌘T)")
                .accessibilityLabel("New tab")

                Spacer(minLength: 0)
            }
            .animation(PaneGroupBar.tabMotion, value: tabs.map(\.id))
        }
        .frame(height: barHeight)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .bottom) { Divider() }
        .alert(
            "Rename Tab",
            isPresented: Binding(
                get: { renamingTabId != nil },
                set: { if !$0 { renamingTabId = nil } }
            ),
            presenting: renamingTabId
        ) { tabId in
            TextField("Title", text: $renameText)
            Button("Rename") {
                let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                onRename(tabId, trimmed.isEmpty ? nil : trimmed)
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}

private struct WorkspaceTabDropDelegate: DropDelegate {
    let targetId: UUID
    let onMove: (UUID, UUID) -> Void

    func dropEntered(info: DropInfo) {
        guard let provider = info.itemProviders(for: [.plainText]).first else { return }
        provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let value = object as? String,
                  let sourceId = UUID(uuidString: value),
                  sourceId != targetId else { return }
            Task { @MainActor in onMove(sourceId, targetId) }
        }
    }

    func performDrop(info: DropInfo) -> Bool { true }
}
