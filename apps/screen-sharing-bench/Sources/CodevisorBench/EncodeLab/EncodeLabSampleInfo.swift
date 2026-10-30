import CoreMedia
import VideoToolbox

struct EncodeLabSampleInfo: @unchecked Sendable {
  let frame: Int
  let submitNs: Int64
  let refresh: Bool
  let sample: CMSampleBuffer?

  var bytes: Int { sample.map(CMSampleBufferGetTotalSampleSize) ?? 0 }

  var keyframe: Bool {
    guard let attachments = firstAttachments else { return sample != nil }

    return (attachments[kCMSampleAttachmentKey_NotSync as String] as? Bool) != true
  }

  var longTermReferenceToken: Int? {
    firstAttachments?[kVTSampleAttachmentKey_RequireLTRAcknowledgementToken as String] as? Int
  }

  func output(tile: Int, outputNs: Int64) -> EncodeLabTileOutput {
    EncodeLabTileOutput(
      frame: frame, tile: tile, submitNs: submitNs, outputNs: outputNs, bytes: bytes, keyframe: keyframe,
      refresh: refresh, sample: sample)
  }

  private var firstAttachments: [String: Any]? {
    guard let sample, let array = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) else {
      return nil
    }

    return (array as? [[String: Any]])?.first
  }
}
