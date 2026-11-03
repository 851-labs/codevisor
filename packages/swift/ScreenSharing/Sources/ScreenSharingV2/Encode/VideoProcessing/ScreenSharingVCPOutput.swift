import CoreMedia
import VideoToolbox

struct ScreenSharingVCPOutput: @unchecked Sendable {
  let submission: UInt64
  let status: OSStatus
  let flags: VTEncodeInfoFlags
  let sample: CMSampleBuffer?

  var dimensions: CMVideoDimensions? {
    sample?.formatDescription.map(CMVideoFormatDescriptionGetDimensions)
  }

}
