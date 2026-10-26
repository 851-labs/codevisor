import CodevisorUI
import SwiftUI

struct ChromiumBrowserAddressToolbarItem: ToolbarContent {
  let model: ChromiumBrowserModel
  var width: CGFloat?

  var body: some ToolbarContent {
    ToolbarItem(placement: .principal) {
      ChromiumBrowserToolbar(model: model)
        .frame(width: width)
    }
    .sharedBackgroundVisibility(.hidden)
  }
}

struct ChromiumBrowserNavigationControls: ToolbarContent {
  @Bindable var model: ChromiumBrowserModel

  var body: some ToolbarContent {
    ToolbarItem(placement: .navigation) {
      ChromiumBrowserNavigationButtons(model: model)
    }
  }
}

struct ChromiumBrowserNavigationButtons: View {
  @Bindable var model: ChromiumBrowserModel

  var body: some View {
    ControlGroup {
      Button("Back", systemImage: "chevron.left") { model.goBack() }
        .disabled(!model.canGoBack)
        .help("Back")
      Button("Forward", systemImage: "chevron.right") { model.goForward() }
        .disabled(!model.canGoForward)
        .help("Forward")
    }
    .controlGroupStyle(.navigation)
  }
}

struct ChromiumBrowserToolbar: NSViewRepresentable {
  let model: ChromiumBrowserModel

  func makeNSView(context: Context) -> ChromiumToolbarHost {
    let view = ChromiumToolbarHost(rootView: ChromiumBrowserToolbarContent(model: model))
    view.model = model
    view.sizingOptions = [.intrinsicContentSize]
    return view
  }

  func updateNSView(_ nsView: ChromiumToolbarHost, context: Context) {
    nsView.model = model
    nsView.rootView = ChromiumBrowserToolbarContent(model: model)
  }

  func sizeThatFits(
    _ proposal: ProposedViewSize, nsView: ChromiumToolbarHost, context: Context
  )
    -> CGSize?
  {
    CGSize(width: min(850, max(280, proposal.width ?? 600)), height: 32)
  }
}

struct ChromiumBrowserToolbarContent: View {
  @Bindable var model: ChromiumBrowserModel
  @State private var address = ""
  @State private var editing = false
  @State private var editedAddress: ChromiumAddressFocus?
  @State private var focusRequest = 0

  var body: some View {
    GlassEffectContainer(spacing: 8) {
      HStack(spacing: 8) {
        HStack(spacing: 0) {
          BrowserAddressEditor(
            text: $address, editing: $editing, focusRequest: focusRequest,
            fullAddress: model.url?.absoluteString ?? "", suggestions: model.suggestions,
            submit: { value in
              model.submitAddress(value)
              editing = false
              model.webView?.focusPage()
            },
            cancel: {
              editing = false
              updateAddress()
              model.webView?.focusPage()
            }
          )
          .padding(.leading, 14)
          if model.pageZoom.canReset {
            browserButton(
              "Zoom: \(model.pageZoom.percent)%",
              symbol: model.pageZoom.percent < 100 ? "minus.magnifyingglass" : "plus.magnifyingglass"
            ) { model.pageZoom.present() }
          }
          browserButton(model.isLoading ? "Stop" : "Reload", symbol: model.isLoading ? "xmark" : "arrow.clockwise") {
            if model.isLoading { model.stop() } else { model.reload() }
          }
        }
        .frame(maxWidth: 720)
        .glassEffect(.regular.interactive(), in: .capsule)
        .background {
          ChromiumBrowserZoomPopover(
            model: model, request: model.pageZoom.presentationRequest, editing: editing, loading: model.isLoading)
        }
        browserButton("Responsive viewport", symbol: "ipad.and.iphone") {
          Task {
            if model.viewport == nil {
              try? await model.setViewport(ChromiumViewport().parameters)
            } else {
              try? await model.resetViewport()
            }
          }
        }
        ChromiumDownloadsButton(downloads: model.downloads)
      }
      .frame(maxWidth: .infinity)
    }
    .frame(minWidth: 280, idealWidth: 600, maxWidth: 850)
    .onAppear {
      updateAddress()
      if model.address.takeRequest() { beginEditing() }
    }
    .onChange(of: model.paneId) { _, _ in
      editedAddress?.isEditing = false
      editedAddress = nil
      editing = false
      updateAddress()
      if model.address.takeRequest() { beginEditing() }
    }
    .onChange(of: model.url) { _, _ in if !editing { updateAddress() } }
    .onChange(of: editing) { _, focused in
      editedAddress?.isEditing = false
      editedAddress = focused ? model.address : nil
      model.address.isEditing = focused
      if !focused { model.suggestions.dismiss(); updateAddress() }
    }
    .onDisappear {
      model.suggestions.dismiss()
      editedAddress?.isEditing = false
      editedAddress = nil
    }
    .onChange(of: model.address.request) { _, _ in
      if model.address.takeRequest() { beginEditing() }
    }
  }
  private func beginEditing() {
    if !editing { address = model.url?.absoluteString ?? "" }
    editing = true
    editedAddress = model.address
    model.address.isEditing = true
    model.suggestions.dismiss()
    focusRequest += 1
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
