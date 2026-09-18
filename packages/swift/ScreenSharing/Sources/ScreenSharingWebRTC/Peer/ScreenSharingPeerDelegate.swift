import Foundation
import QuartzCore
@preconcurrency import WebRTC
import ScreenSharing

final class ScreenSharingPeerDelegate: NSObject, RTCPeerConnectionDelegate, @unchecked Sendable {
  var onGathered: (@Sendable () -> Void)?
  var onConnection: (@Sendable (String) -> Void)?
  var onVideoTrack: (@Sendable (RTCVideoTrack) -> Void)?
  func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
  func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
  func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
  func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
  func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
  func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
    if newState == .complete { onGathered?() }
  }
  func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {}
  func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
  func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) { dataChannel.close() }
  func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
    let names = ["new", "connecting", "connected", "disconnected", "failed", "closed"]
    onConnection?(names[min(max(0, newState.rawValue), names.count - 1)])
  }
  func peerConnection(
    _ peerConnection: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver, streams: [RTCMediaStream]
  ) {
    if let track = rtpReceiver.track as? RTCVideoTrack { onVideoTrack?(track) }
  }
}
