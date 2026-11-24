import CoreTransferable
import Foundation
import UniformTypeIdentifiers

public struct FileTransferItem: Sendable {
  public let name: String
  public let mimeType: String
  public let load: @Sendable () async throws -> Data

  public init(name: String, mimeType: String, load: @escaping @Sendable () async throws -> Data) {
    self.name = name
    self.mimeType = mimeType
    self.load = load
  }
}

@MainActor
public struct FileTransfers {
  public var download: (@MainActor (FileTransferItem) -> Void)?
  public var saveAs: (@MainActor (FileTransferItem) -> Void)?
  public var share: (@MainActor (FileTransferItem) -> Void)?
  public var reportFailure: (@MainActor (_ title: String, _ message: String) -> Void)?

  public init(
    download: (@MainActor (FileTransferItem) -> Void)? = nil,
    saveAs: (@MainActor (FileTransferItem) -> Void)? = nil,
    share: (@MainActor (FileTransferItem) -> Void)? = nil,
    reportFailure: (@MainActor (_ title: String, _ message: String) -> Void)? = nil
  ) {
    self.download = download
    self.saveAs = saveAs
    self.share = share
    self.reportFailure = reportFailure
  }

  public static let downloadSymbol = "arrow.down.to.line"

  public static var saveAsTitle: String {
    #if os(iOS)
      "Save to Files"
    #else
      "Save As…"
    #endif
  }
}
