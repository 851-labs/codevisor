#if os(macOS)
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
        VStack(spacing: 0) {
          content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
          SheetFooter {
            Button("Cancel", role: .cancel) { dismiss() }
              .keyboardShortcut(.cancelAction)
            Button("Add") {
              if let selectedHarness { add(selectedHarness) }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(selectedHarness == nil)
          }
        }
      }
      .searchable(text: $search, placement: .toolbar, prompt: "Search harnesses")
      .frame(width: 480, height: 480)
      .onChange(of: search) { _, _ in
        if selectedHarness == nil { selection = nil }
      }
    }

    @ViewBuilder
    private var content: some View {
      if isLoading && harnesses.isEmpty {
        ProgressView().accessibilityLabel("Loading harnesses")
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
        List(selection: $selection) {
          ForEach(filteredHarnesses) { harness in
            HStack(spacing: 12) {
              icon(harness.id, harness.symbolName)
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)
              Text(harness.name)
              Spacer()
            }
            .frame(minHeight: 40)
            .contentShape(Rectangle())
            .tag(harness.id)
            .accessibilityElement(children: .combine)
          }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
      }
    }
  }

#endif
