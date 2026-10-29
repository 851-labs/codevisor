import ScreenSharing
import ScreenSharingBench

enum LoopbackCandidates {
  static func hostAddress(in sdp: String) throws -> BenchUDPAddress {
    guard let candidate = ScreenSharingTunnelSDP.localIPv4Candidate(inOffer: sdp) else {
      throw RelayError.noHostCandidate
    }

    return try BenchUDPAddress(host: candidate.address, port: candidate.port)
  }

  static func routed(_ sdp: String, through relay: BenchUDPAddress) -> String {
    ScreenSharingTunnelSDP.answer(sdp, routedTo: relay.host, port: relay.port)
  }
}
