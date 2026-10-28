import Foundation

@MainActor
public enum SentAttachmentAliases {
  private static let capacity = 16
  private static var sentFileIDs: [(uploaded: String, sent: String)] = []

  static func remember(uploaded: String, sentAs sent: String) {
    sentFileIDs.removeAll { $0.uploaded == uploaded }
    sentFileIDs.append((uploaded, sent))
    if sentFileIDs.count > capacity { sentFileIDs.removeFirst(sentFileIDs.count - capacity) }
  }

  public static func sentFileID(forUploaded fileId: String) -> String? {
    sentFileIDs.last { $0.uploaded == fileId }?.sent
  }
}
