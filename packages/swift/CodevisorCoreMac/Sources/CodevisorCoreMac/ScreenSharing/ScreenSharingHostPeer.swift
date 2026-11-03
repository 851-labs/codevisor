import CoreVideo
import Foundation
import ScreenSharing
import ScreenSharingV2
import ScreenSharingWebRTC

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

@MainActor
protocol ScreenSharingHostPeer: AnyObject {
  var channels: ScreenSharingHostChannels { get }
  var frameSink: any ScreenSharingFrameSink { get }
  var sendAudioPacket: @Sendable (ScreenSharingAudioMessage) -> Bool { get }
  var capturePixelFormat: OSType? { get }
  var onConnectionChanged: ((String) -> Void)? { get set }
  func statistics() async -> [String: String]
  func updateVideoConfiguration(_ configuration: ScreenSharingVideoConfiguration)
  func captureConfiguration(width: Int, height: Int) throws -> ScreenSharingVideoConfiguration
  func close()
}

extension ScreenSharingSender: ScreenSharingHostPeer {
  var channels: ScreenSharingHostChannels {
    .init(
      control: controlChannel, clipboard: clipboardChannel, clipboardSharing: clipboardSharingChannel,
      cursor: cursorChannel, audio: audioChannel, display: displayChannel, videoFormat: videoFormatChannel)
  }

  var frameSink: any ScreenSharingFrameSink { frameSender }

  var sendAudioPacket: @Sendable (ScreenSharingAudioMessage) -> Bool {
    { [weak audioChannel] in audioChannel?.send($0) ?? false }
  }

  var capturePixelFormat: OSType? { nil }

  func captureConfiguration(width: Int, height: Int) throws -> ScreenSharingVideoConfiguration {
    try ScreenSharingVideoConfiguration(width: width, height: height, bitrate: ScreenSharingProductProfile.bitrateCeiling)
  }
}

extension ScreenSharingV2HostLink: ScreenSharingHostPeer {
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
