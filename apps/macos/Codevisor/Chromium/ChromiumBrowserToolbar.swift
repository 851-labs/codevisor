import CodevisorUI
import SwiftUI

struct ChromiumBrowserNavigationControls: ToolbarContent {
  @Bindable var model: ChromiumBrowserModel

  var body: some ToolbarContent {
    ToolbarItem(placement: .navigation) {
      ControlGroup {
        Button("Back", systemImage: "chevron.left") { model.webView?.goBack() }
          .disabled(!model.canGoBack)
          .help("Back")
        Button("Forward", systemImage: "chevron.right") { model.webView?.goForward() }
          .disabled(!model.canGoForward)
          .help("Forward")
      }
      .controlGroupStyle(.navigation)
    }
  }
}

/// Window controls share the pane model without owning its browser lifetime.
struct ChromiumBrowserToolbar: NSViewRepresentable {
  let model: ChromiumBrowserModel

  // Keep the composite toolbar inside one native view. Otherwise SwiftUI's
  // toolbar adaptation promotes the first button's action and accessibility
  // metadata to the other controls, leaving the address editor inert.
  func makeNSView(context: Context) -> NSHostingView<ChromiumBrowserToolbarContent> {
    let view = NSHostingView(rootView: ChromiumBrowserToolbarContent(model: model))
    view.sizingOptions = [.intrinsicContentSize]
    return view
  }

  func updateNSView(_ nsView: NSHostingView<ChromiumBrowserToolbarContent>, context: Context) {
    nsView.rootView = ChromiumBrowserToolbarContent(model: model)
  }

  func sizeThatFits(
    _ proposal: ProposedViewSize, nsView: NSHostingView<ChromiumBrowserToolbarContent>, context: Context
  )
    -> CGSize?
  {
    CGSize(width: min(850, max(280, proposal.width ?? 600)), height: 32)
  }
}

struct ChromiumBrowserToolbarContent: View {
  @Bindable var model: ChromiumBrowserModel
  @State private var address = ""
  @FocusState private var editing: Bool
  @State private var selection: TextSelection?

  var body: some View {
    GlassEffectContainer(spacing: 8) {
      HStack(spacing: 8) {
        HStack(spacing: 0) {
          Button {
            beginEditing()
          } label: {
            Text(model.url.map(BrowserLocation.display) ?? "Search or enter website name")
              .font(.body)
              .lineLimit(1)
              .truncationMode(.middle)
              .frame(maxWidth: .infinity)
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .opacity(editing ? 0 : 1)
          .accessibilityHidden(editing)
          .accessibilityLabel("Website address")
          .overlay {
            TextField("Search or enter website name", text: $address, selection: $selection)
              .textFieldStyle(.plain)
              .font(.body)
              .focused($editing)
              .onSubmit {
                model.submitAddress(address)
                editing = false
                model.webView?.focusPage()
              }
              .onExitCommand {
                editing = false
                updateAddress()
                model.webView?.focusPage()
              }
              .opacity(editing ? 1 : 0)
              .allowsHitTesting(editing)
              .accessibilityHidden(!editing)
              .accessibilityLabel("Website address")
          }
          .padding(.leading, 14)
          browserButton(model.isLoading ? "Stop" : "Reload", symbol: model.isLoading ? "xmark" : "arrow.clockwise") {
            if model.isLoading { model.stop() } else { model.reload() }
          }
        }
        .frame(maxWidth: 720)
        .glassEffect(.regular.interactive(), in: .capsule)
        browserButton("Responsive viewport", symbol: "iphone.and.ipad") {
          Task {
            if model.viewport == nil {
              try? await model.setViewport(ChromiumViewport().parameters)
            } else {
              try? await model.resetViewport()
            }
          }
        }
      }
      .frame(maxWidth: .infinity)
    }
    .frame(minWidth: 280, idealWidth: 600, maxWidth: 850)
    .onAppear { updateAddress() }
    .onChange(of: model.url) { _, _ in if !editing { updateAddress() } }
    .onChange(of: editing) { _, focused in
      if focused { address = model.url?.absoluteString ?? "" } else { updateAddress() }
    }
    .onChange(of: model.addressFocusRequest) { _, _ in beginEditing() }
  }
  private func beginEditing() {
    address = model.url?.absoluteString ?? ""
    editing = true
    selection = TextSelection(range: address.startIndex..<address.endIndex)
  }

  private func updateAddress() { address = model.url.map(BrowserLocation.display) ?? "" }
  private func browserButton(
    _ title: String, symbol: String, action: @escaping () -> Void
  ) -> some View {
    Button(action: action) { Image(systemName: symbol).frame(width: 34, height: 32) }
      .buttonStyle(.plain)
      .help(title)
      .accessibilityLabel(title)
  }
}
