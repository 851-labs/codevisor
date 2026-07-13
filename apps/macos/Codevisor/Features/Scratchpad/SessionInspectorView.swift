import SwiftUI
import AppKit
import ACPKit
import CodevisorCore

/// The tabs the session inspector can show. Add cases here as new panels
/// land; the segmented control at the top of the inspector renders one
/// segment per case.
enum SessionInspectorTab: String, CaseIterable, Identifiable {
    case info
    case notes

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .info: "info"
        case .notes: "note.text"
        }
    }

    var title: String {
        switch self {
        case .info: "Info"
        case .notes: "Notes"
        }
    }
}

/// The session inspector: a segmented control (SF Symbols-inspector style)
/// switching between panels — session info (usage/cost) and the notes
/// scratchpad. The selected tab is remembered app-wide, not per session,
/// matching how system inspectors behave.
struct SessionInspectorView: View {
    let controller: SessionController?
    @Bindable var scratchpad: ScratchpadModel

    @AppStorage("inspector.selectedTab") private var selectedTabRaw = SessionInspectorTab.notes.rawValue

    private var selectedTab: Binding<SessionInspectorTab> {
        Binding(
            get: { SessionInspectorTab(rawValue: selectedTabRaw) ?? .notes },
            set: { selectedTabRaw = $0.rawValue }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            InspectorTabPicker(selection: selectedTab)
                .padding(.horizontal, 12)
                .padding(.top, 8)
                // Breathing room between the tab strip and panel content.
                .padding(.bottom, 10)

            switch selectedTab.wrappedValue {
            case .info:
                SessionInfoPanel(usage: controller?.usage)
            case .notes:
                ScratchpadNotesView(model: scratchpad)
            }
        }
        // Panels size to their content; pin the stack (and with it the
        // segmented control) to the top of the inspector column.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// The inspector's tab strip. SwiftUI's segmented `Picker` on macOS always
/// hugs its content — `.frame(maxWidth: .infinity)` just centers it in a
/// wider frame — so this wraps `NSSegmentedControl`, which stretches to the
/// proposed width and distributes segments equally (the SF Symbols-inspector
/// look).
private struct InspectorTabPicker: NSViewRepresentable {
    @Binding var selection: SessionInspectorTab

    func makeCoordinator() -> Coordinator {
        Coordinator(selection: $selection)
    }

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl(
            images: SessionInspectorTab.allCases.map { tab in
                NSImage(systemSymbolName: tab.systemImage, accessibilityDescription: tab.title)
                    ?? NSImage()
            },
            trackingMode: .selectOne,
            target: context.coordinator,
            action: #selector(Coordinator.selectionChanged(_:))
        )
        control.segmentDistribution = .fillEqually
        for (index, tab) in SessionInspectorTab.allCases.enumerated() {
            control.setToolTip(tab.title, forSegment: index)
        }
        return control
    }

    /// Fill the proposed width (the inspector column) instead of the
    /// control's intrinsic size; `fillEqually` then splits it into equal
    /// segments.
    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: NSSegmentedControl,
        context: Context
    ) -> NSSize? {
        guard let width = proposal.width, width.isFinite else { return nil }
        return NSSize(width: width, height: nsView.intrinsicContentSize.height)
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.selection = $selection
        control.selectedSegment = SessionInspectorTab.allCases.firstIndex(of: selection) ?? 0
    }

    @MainActor
    final class Coordinator: NSObject {
        var selection: Binding<SessionInspectorTab>

        init(selection: Binding<SessionInspectorTab>) {
            self.selection = selection
        }

        @objc func selectionChanged(_ sender: NSSegmentedControl) {
            let tabs = SessionInspectorTab.allCases
            guard tabs.indices.contains(sender.selectedSegment) else { return }
            selection.wrappedValue = tabs[sender.selectedSegment]
        }
    }
}

/// The Info panel: the session's reported token usage and cost. Values come
/// from the agent's `usage_update` (same source as the composer's usage
/// ring); until one arrives there is nothing to show.
struct SessionInfoPanel: View {
    var usage: SessionUsage?

    var body: some View {
        if let usage, usage.used != nil || usage.cost != nil {
            Form {
                if let cost = usage.cost {
                    LabeledContent("Cost", value: UsageFormatting.formatCost(cost))
                }
                if let used = usage.used {
                    LabeledContent("Tokens", value: UsageFormatting.formatTokens(used, size: usage.size))
                    if let size = usage.size, size > 0 {
                        LabeledContent(
                            "Context",
                            value: String(format: "%.0f%% used", min(Double(used) / Double(size), 1) * 100)
                        )
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        } else {
            ContentUnavailableView(
                "No Usage Yet",
                systemImage: "chart.pie",
                description: Text("Token usage and cost appear once the agent reports them.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

#Preview("Inspector") {
    SessionInspectorView(
        controller: nil,
        scratchpad: ScratchpadModel(
            sessionId: UUID(),
            repository: DefaultScratchpadRepository(store: InMemoryStore())
        )
    )
    .frame(width: 300, height: 480)
}

#Preview("Info panel with usage") {
    SessionInfoPanel(
        usage: SessionUsage(
            used: 18_432,
            size: 200_000,
            cost: SessionCost(amount: 0.0142, currency: "USD")
        )
    )
    .frame(width: 300, height: 480)
}
