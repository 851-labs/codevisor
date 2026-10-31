import CodevisorCore
import Foundation
import UniformTypeIdentifiers
import WebKit

@MainActor
final class FileHTMLSchemeHandler: NSObject, WKURLSchemeHandler {
  private static let webTypes: [String: String] = [
    "html": "text/html", "htm": "text/html", "css": "text/css", "js": "text/javascript",
    "mjs": "text/javascript", "json": "application/json", "svg": "image/svg+xml", "wasm": "application/wasm",
  ]

  private let address: FileHTMLPreviewAddress
  private let pageText: @MainActor () -> String
  private let read: @Sendable (String) async throws -> ServerFileContents
  private let version: @Sendable (String) async throws -> String?
  private var running: [ObjectIdentifier: Task<Void, Never>] = [:]
  private var versions: [String: String] = [:]

  init(
    address: FileHTMLPreviewAddress, pageText: @escaping @MainActor () -> String,
    read: @escaping @Sendable (String) async throws -> ServerFileContents,
    version: @escaping @Sendable (String) async throws -> String?
  ) {
    self.address = address
    self.pageText = pageText
    self.read = read
    self.version = version
  }

  func resourcesChanged() async -> Bool {
    for (path, served) in versions {
      if await hasChanged(path, from: served) { return true }
    }
    return false
  }

  func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
    let id = ObjectIdentifier(task)
    running[id] = Task { [weak self] in
      await self?.serve(task)
      self?.running[id] = nil
    }
  }

  func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {
    running.removeValue(forKey: ObjectIdentifier(task))?.cancel()
  }

  private func serve(_ task: any WKURLSchemeTask) async {
    do {
      let (data, response) = try await contents(of: task.request.url)
      guard isRunning(task) else { return }

      task.didReceive(response)
      task.didReceive(data)
      task.didFinish()
    } catch {
      guard isRunning(task) else { return }

      task.didFailWithError(error)
    }
  }

  private func isRunning(_ task: any WKURLSchemeTask) -> Bool {
    !Task.isCancelled && running[ObjectIdentifier(task)] != nil
  }

  private func contents(of url: URL?) async throws -> (Data, URLResponse) {
    guard let url, let path = FileHTMLPreviewAddress.path(of: url) else { throw URLError(.badURL) }
    guard address.allows(path) else { throw URLError(.noPermissionsToReadFile) }

    if path == address.page {
      versions.removeAll()
      return (Data(pageText().utf8), Self.response(url, type: "text/html; charset=utf-8"))
    }
    let file = try await read(path)
    versions[path] = file.version
    return (file.data, Self.response(url, type: Self.mimeType(of: path)))
  }

  private func hasChanged(_ path: String, from served: String) async -> Bool {
    do {
      return try await version(path) != served
    } catch {
      return serverErrorCode(error) == "not_found"
    }
  }

  private static func response(_ url: URL, type: String) -> URLResponse {
    HTTPURLResponse(
      url: url, statusCode: 200, httpVersion: "HTTP/1.1",
      headerFields: ["Content-Type": type, "Cache-Control": "no-store"])!
  }

  private static func mimeType(of path: String) -> String {
    let fileExtension = (path as NSString).pathExtension.lowercased()
    return webTypes[fileExtension] ?? UTType(filenameExtension: fileExtension)?.preferredMIMEType
      ?? "application/octet-stream"
  }
}
