#if os(iOS)
  import CodevisorCore
  import SwiftUI

  struct HarnessPickerSheet<Icon: View>: View {
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var selection: String?

    let harnesses: [ServerHarness]
    let isLoading: Bool
    let loadFailed: Bool
    let retry: () -> Void
    let add: (ServerHarness) -> Void
    @ViewBuilder let icon: (String, String) -> Icon

    private var filteredHarnesses: [ServerHarness] {
      let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
      return harnesses.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
    }

    private var selectedHarness: ServerHarness? {
      filteredHarnesses.first { $0.id == selection }
    }

    var body: some View {
      NavigationStack {
        content
          .navigationTitle("Add Harness")
          .navigationBarTitleDisplayMode(.inline)
          .toolbar {
            ToolbarItem(placement: .cancellationAction) {
              Button("Cancel", role: .cancel) { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
              Button("Add", role: .confirm) {
                if let selectedHarness { add(selectedHarness) }
              }
              .disabled(selectedHarness == nil)
            }
          }
      }
      .searchable(text: $search, prompt: "Search harnesses")
      .searchPresentationToolbarBehavior(.avoidHidingContent)
      .onChange(of: search) { _, _ in
        if selectedHarness == nil { selection = nil }
      }
    }

    @ViewBuilder
    private var content: some View {
      if isLoading && harnesses.isEmpty {
        SheetLoadingView("Loading harnesses…")
      } else if loadFailed && harnesses.isEmpty {
        ContentUnavailableView {
          Label("Machines Unavailable", systemImage: "desktopcomputer.trianglebadge.exclamationmark")
        } actions: {
          Button("Try Again", action: retry)
        }
      } else if harnesses.isEmpty {
        ContentUnavailableView("All Harnesses Added", systemImage: "checkmark.circle")
      } else if filteredHarnesses.isEmpty {
        ContentUnavailableView.search(text: search)
      } else {
        List(filteredHarnesses) { harness in
          Button {
            selection = harness.id
          } label: {
            HStack(spacing: 12) {
              icon(harness.id, harness.symbolName)
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)
              Text(harness.name)
                .foregroundStyle(.primary)
              Spacer()
              Image(systemName: "checkmark")
                .foregroundStyle(.tint)
                .opacity(selection == harness.id ? 1 : 0)
                .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .accessibilityAddTraits(selection == harness.id ? .isSelected : [])
        }
      }
    }
  }
#endif
