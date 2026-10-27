import SwiftUI
import WebKit

#if canImport(AppKit)
  struct PluginAppWebView: NSViewRepresentable {
    let controller: PluginAppWebController

    func makeNSView(context: Context) -> WKWebView {
      controller.webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
  }
#else
  struct PluginAppWebView: UIViewRepresentable {
    let controller: PluginAppWebController

    func makeUIView(context: Context) -> WKWebView {
      controller.webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
  }
#endif
