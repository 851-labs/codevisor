import CoreMedia
import VideoToolbox

struct EncodeLabVCPAttachments {
  static let tileKey = "TileID"
  static let droppedTile = -1

  let tile: Int
  let token: Int?

  init(_ sample: CMSampleBuffer?, tokenKey: CFString) {
    let attachments = Self.first(sample)
    tile = attachments?[Self.tileKey] as? Int ?? (sample == nil ? Self.droppedTile : 0)
    token = attachments?[tokenKey as String] as? Int
  }

  private static func first(_ sample: CMSampleBuffer?) -> [String: Any]? {
    guard let sample, let array = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) else {
      return nil
    }

    return (array as? [[String: Any]])?.first
  }
}
