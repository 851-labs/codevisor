import AppKit
import CodevisorClient
import Foundation
import Testing
import WebKit

@testable import CodevisorUI

@MainActor
@Suite("File HTML preview in WebKit", .timeLimit(.minutes(1)))
struct FileHTMLPreviewWebKitTests {
  private let address = FileHTMLPreviewAddress(document: "/work/site/index.html", rootPath: "/work/app")
  private let site = FakeSite()

  @Test func pagesLoadTheirRelativeResourcesButCannotReadOtherFiles() async throws {
    let handler = handler()
    let view = try await load(handler)
    defer { view.stopLoading() }

    let color = try await view.evaluateJavaScript("getComputedStyle(document.body).color") as? String
    let outside =
      try await view.callAsyncJavaScript(
        "try { await fetch('/etc/hosts'); return 'read' } catch { return 'blocked' }",
        arguments: [:], in: nil, contentWorld: .page) as? String

    #expect(color == "rgb(1, 2, 3)")
    #expect(outside == "blocked")
    #expect(await site.reads == ["/work/site/style.css"])
  }

  @Test func changesToFilesThePageLoadedAreDetected() async throws {
    let handler = handler()
    let view = try await load(handler)
    defer { view.stopLoading() }

    #expect(!(await handler.resourcesChanged()))
    await site.change("/work/site/other.css")
    #expect(!(await handler.resourcesChanged()))
    await site.change("/work/site/style.css")
    #expect(await handler.resourcesChanged())
  }

  @Test func deletedResourcesCountAsChangedButUnreachableMachinesDoNot() async throws {
    let handler = handler()
    let view = try await load(handler)
    defer { view.stopLoading() }

    await site.fail(with: URLError(.notConnectedToInternet))
    #expect(!(await handler.resourcesChanged()))
    await site.fail(with: CodevisorServerClientError.httpStatus(404, #"{"code":"not_found","error":"Deleted"}"#))
    #expect(await handler.resourcesChanged())
  }

  private func handler() -> FileHTMLSchemeHandler {
    FileHTMLSchemeHandler(
      address: address, pageText: { #"<!doctype html><link rel="stylesheet" href="style.css"><body>hi</body>"# },
      read: { [site] in await site.read($0) }, version: { [site] in try await site.version($0) })
  }

  private func load(_ handler: FileHTMLSchemeHandler) async throws -> WKWebView {
    _ = NSApplication.shared
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    configuration.setURLSchemeHandler(handler, forURLScheme: FileHTMLPreviewAddress.scheme)
    let view = WKWebView(frame: .zero, configuration: configuration)
    try await PageLoad().load(view, url: address.pageURL)
    return view
  }
}

private actor FakeSite {
  private(set) var reads: [String] = []
  private var versions: [String: String] = [:]
  private var failure: (any Error)?

  func read(_ path: String) -> ServerFileContents {
    reads.append(path)
    return ServerFileContents(data: Data("body { color: rgb(1, 2, 3) }".utf8), version: versions[path, default: "1"])
  }

  func version(_ path: String) throws -> String? {
    if let failure { throw failure }
    return versions[path, default: "1"]
  }

  func change(_ path: String) { versions[path] = "2" }

  func fail(with error: any Error) { failure = error }
}

@MainActor
private final class PageLoad: NSObject, WKNavigationDelegate {
  private var continuation: CheckedContinuation<Void, any Error>?

  func load(_ view: WKWebView, url: URL) async throws {
    view.navigationDelegate = self
    defer { view.navigationDelegate = nil }
    try await withCheckedThrowingContinuation { continuation in
      self.continuation = continuation
      view.load(URLRequest(url: url))
    }
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish(.success(())) }

  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
    finish(.failure(error))
  }

  func webView(
    _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error
  ) {
    finish(.failure(error))
  }

  private func finish(_ result: Result<Void, any Error>) {
    continuation?.resume(with: result)
    continuation = nil
  }
}
