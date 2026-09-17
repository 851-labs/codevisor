#if os(macOS)
  import Autocomplete
  import CodevisorCore
  import SwiftUI

  struct HarnessAddMenu<Icon: View>: View {
    @Binding var isPresented: Bool
    let harnesses: [ServerHarness]
    let isLoading: Bool
    let loadFailed: Bool
    let retry: () -> Void
    let add: (ServerHarness) -> Void
    @ViewBuilder let icon: (String, String) -> Icon

    private var loadingState: Autocomplete.LoadingState {
      if isLoading && harnesses.isEmpty { return .loading("Loading harnesses…") }
      if loadFailed && harnesses.isEmpty { return .failure("Machines Unavailable") }
      return .ready
    }

    var body: some View {
      Autocomplete.Menu(isPresented: $isPresented) {
        for harness in harnesses {
          Autocomplete.Action(
            harness.name, id: harness.id,
            action: {
              isPresented = false
              add(harness)
            }
          ) {
            icon(harness.id, harness.symbolName).frame(width: 18, height: 18)
          } label: {
            Text(harness.name)
          }
        }
        if loadFailed {
          Autocomplete.Footer(id: "retry") {
            Autocomplete.Action("Try Again", systemImage: "arrow.clockwise", action: retry)
              .disabled(isLoading)
          }
        }
      } label: {
        Label("Add Harness…", systemImage: "plus")
      }
      .autocompleteSearchPrompt("Search harnesses")
      .autocompleteSearchLabel("Search harnesses")
      .autocompleteEmptyMessage("No Matching Harnesses", noItems: "All Harnesses Added")
      .autocompleteLoadingState(loadingState)
      // Adding closes the menu; retrying keeps its loading state visible.
      .autocompleteDismissBehavior(.never)
    }
  }
#endif
