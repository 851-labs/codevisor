import Foundation

nonisolated struct ChromiumAutomationDownload: Sendable {
  enum State: String, Sendable {
    case inProgress
    case completed
    case canceled
  }

  var id: UInt32
  var path: String
  var url: String
  var suggestedFilename: String
  var receivedBytes: Int64
  var totalBytes: Int64
  var state: State

  init(_ download: CVChromiumDownload) {
    id = download.identifier
    path = download.path
    url = download.url
    suggestedFilename = (download.path as NSString).lastPathComponent
    receivedBytes = download.receivedBytes
    totalBytes = download.totalBytes
    state = Self.state(of: download.state)
  }

  func began(guid: String) -> [String: Any] {
    event(
      "Browser.downloadWillBegin", ["frameId": "", "guid": guid, "url": url, "suggestedFilename": suggestedFilename])
  }

  func progress(guid: String, state: State) -> [String: Any] {
    event(
      "Browser.downloadProgress",
      ["guid": guid, "totalBytes": totalBytes, "receivedBytes": receivedBytes, "state": state.rawValue])
  }

  func data(guid: String, chunk: Data) -> [String: Any] {
    event("Codevisor.downloadData", ["guid": guid, "data": chunk.base64EncodedString()])
  }

  private func event(_ method: String, _ params: [String: Any]) -> [String: Any] {
    ["method": method, "params": params]
  }

  private static func state(of state: CVChromiumDownloadState) -> State {
    switch state {
    case .inProgress: .inProgress
    case .complete: .completed
    default: .canceled
    }
  }
}
