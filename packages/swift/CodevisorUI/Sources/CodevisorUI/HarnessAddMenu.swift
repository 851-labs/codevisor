#if os(macOS)
  import Autocomplete
  import CodevisorCore
  import SwiftUI

  struct HarnessAddMenu: View {
    @Binding var isPresented: Bool
    let harnesses: [HarnessFleet.CatalogEntry]
    let add: @MainActor (HarnessFleet.CatalogEntry) -> Void

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
            CodevisorSymbol.harness(harness.id, fallback: harness.symbolName)
          } label: {
            Text(harness.name)
          }
        }
      } label: {
        Label("Add Harness…", systemImage: "plus")
      }
      .autocompleteSearchPrompt("Search harnesses")
      .autocompleteSearchLabel("Search harnesses")
      .autocompleteEmptyMessage("No Matching Harnesses", noItems: "All Harnesses Added")
      .autocompleteDismissBehavior(.never)
    }
  }
#endif
