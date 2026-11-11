#if canImport(AppKit)
  import SwiftUI

  extension Autocomplete {
    struct MenuPopover: ViewModifier {
      let isPresented: Binding<Bool>
      let content: () -> [Entry]
      @Environment(\.isEnabled) private var isEnabled

      func body(content view: Content) -> some View {
        view
          .popover(isPresented: isPresented, attachmentAnchor: .rect(.bounds), arrowEdge: .bottom) {
            Surface(entries: content(), mode: .menu, onDismiss: { isPresented.wrappedValue = false })
              .disabled(!isEnabled)
          }
          .onChange(of: isEnabled) { _, enabled in
            if !enabled { isPresented.wrappedValue = false }
          }
      }
    }
  }

  public extension View {
    func autocompleteMenu(
      isPresented: Binding<Bool>, @Autocomplete.ContentBuilder content: @escaping () -> [Autocomplete.Entry]
    ) -> some View {
      modifier(Autocomplete.MenuPopover(isPresented: isPresented, content: content))
    }
  }
#endif
