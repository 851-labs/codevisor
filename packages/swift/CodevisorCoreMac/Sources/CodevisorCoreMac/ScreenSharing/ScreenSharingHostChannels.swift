import CoreVideo
import Foundation
import ScreenSharing
import ScreenSharingV2

@MainActor
struct ScreenSharingHostChannels {
  let control: any ScreenSharingMessageChannel<ScreenSharingControlMessage>
  let clipboard: any ScreenSharingMessageChannel<ScreenSharingClipboardMessage>
  let clipboardSharing: any ScreenSharingMessageChannel<ScreenSharingClipboardSharingMessage>
  let cursor: any ScreenSharingMessageChannel<ScreenSharingCursorMessage>
  let audio: any ScreenSharingMessageChannel<ScreenSharingAudioMessage>
  let display: any ScreenSharingMessageChannel<ScreenSharingDisplayMessage>
  let videoFormat: any ScreenSharingMessageChannel<ScreenSharingVideoFormatMessage>
}

extension ScreenSharingV2HostLink {
  var channels: ScreenSharingHostChannels {
    let channels = linkChannels
    return .init(
      control: channels.control, clipboard: channels.clipboard, clipboardSharing: channels.clipboardSharing,
      cursor: channels.cursor, audio: channels.audio, display: channels.display, videoFormat: channels.videoFormat)
  }

  var frameSink: any ScreenSharingFrameSink { frameRouter }

  var sendAudioPacket: @Sendable (ScreenSharingAudioMessage) -> Bool {
    { [sendDatagram] in sendDatagram(.audio, $0.encoded()) }
  }

  var capturePixelFormat: OSType? { sourcePixelFormat }

  func captureConfiguration(width: Int, height: Int) throws -> ScreenSharingVideoConfiguration {
    try ScreenSharingV2Profile.captureConfiguration(width: width, height: height)
  }
}
