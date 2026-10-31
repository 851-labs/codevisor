import CodevisorCore
import SwiftUI
import WebKit

struct FileHTMLPreview: View {
  let document: FileDocumentModel
  let rootPath: String
  let client: any CodevisorServerClienting
  let openFile: (String) -> Bool
  let openWebLink: (URL) -> Bool
  @Environment(\.openURL) private var openURL
  @Environment(\.scenePhase) private var scenePhase

  var body: some View {
    FileHTMLWebView(
      document: document, address: FileHTMLPreviewAddress(document: document.path, rootPath: rootPath),
      text: document.text, isActive: scenePhase == .active, client: client, openFile: openFile,
      openWebLink: { url in if !openWebLink(url) { openURL(url) } },
      openExternally: { openURL($0) }
    )
    .id(document.path)
  }
}

@MainActor
private struct FileHTMLWebView {
  let document: FileDocumentModel
  let address: FileHTMLPreviewAddress
  let text: String
  let isActive: Bool
  let client: any CodevisorServerClienting
  let openFile: (String) -> Bool
  let openWebLink: (URL) -> Void
  let openExternally: (URL) -> Void

  func makeCoordinator() -> FileHTMLPreviewController {
    let resources = FileHTMLSchemeHandler(
      address: address, pageText: { [weak document] in document?.text ?? "" },
      read: { [client] in try await client.documentContents(path: $0) },
      version: { [client] in try await client.documentVersion(path: $0) })
    return FileHTMLPreviewController(address: address, text: text, resources: resources)
  }

  private func update(_ controller: FileHTMLPreviewController) {
    controller.openFile = openFile
    controller.openWebLink = openWebLink
    controller.openExternally = openExternally
    controller.watchesResources = isActive
    controller.show(text)
  }
}

#if canImport(AppKit)
  extension FileHTMLWebView: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView { context.coordinator.webView }
    func updateNSView(_ view: WKWebView, context: Context) { update(context.coordinator) }
    static func dismantleNSView(_ view: WKWebView, coordinator: FileHTMLPreviewController) {
      coordinator.stopWatching()
    }
  }
#else
  extension FileHTMLWebView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView { context.coordinator.webView }
    func updateUIView(_ view: WKWebView, context: Context) { update(context.coordinator) }
    static func dismantleUIView(_ view: WKWebView, coordinator: FileHTMLPreviewController) {
      coordinator.stopWatching()
    }
  }
#endif
