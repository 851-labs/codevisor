import CodevisorUI
import SwiftUI

struct ChromiumBrowserPaneView: View {
  @Bindable var model: ChromiumBrowserModel
  @State private var address = ""
  @FocusState private var editing: Bool
  @State private var selection: TextSelection?

  var body: some View {
    VStack(spacing: 0) {
      GlassEffectContainer(spacing: 8) {
        HStack(spacing: 8) {
          HStack(spacing: 0) {
            browserButton("Back", symbol: "chevron.left", disabled: !model.canGoBack) { model.webView?.goBack() }
            if model.canGoForward {
              browserButton("Forward", symbol: "chevron.right") { model.webView?.goForward() }
            }
          }
          .glassEffect(.regular.interactive(), in: .capsule)
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
      .padding(.horizontal, 10)
      .padding(.vertical, 8)
      .background(.ultraThinMaterial)
      if model.viewport != nil { ChromiumViewportControls(model: model) }
      ZStack {
        if let view = model.webView { ChromiumContent(view: view) }
        if let error = model.errorMessage {
          ContentUnavailableView {
            Label("Couldn’t Load Page", systemImage: "network.slash")
          } description: {
            Text(error)
          } actions: {
            Button("Try Again") { model.reload() }
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .background(.background)
        } else if model.webView == nil {
          ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .onAppear {
      updateAddress(); model.setVisible(true)
    }
    .onDisappear { model.setVisible(false) }
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
    _ title: String, symbol: String, disabled: Bool = false, action: @escaping () -> Void
  ) -> some View {
    Button(action: action) { Image(systemName: symbol).frame(width: 34, height: 32) }
      .buttonStyle(.plain)
      .disabled(disabled)
      .help(title)
      .accessibilityLabel(title)
  }
}

private struct ChromiumContent: NSViewRepresentable {
  let view: CVChromiumView
  func makeNSView(context: Context) -> CVChromiumView { view }
  func updateNSView(_ nsView: CVChromiumView, context: Context) {}
}
