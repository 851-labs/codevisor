import Testing

@testable import CodevisorBench

struct ProcessTotalsTests {
  @Test func addsEveryProcessByNameOverTheRun() throws {
    let start = ProcessListing(
      sampledNs: 0,
      psOutput: """
          10   0:01.00 /usr/libexec/avconferenced
          20   1:00.00 /System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer
          30   0:00.50 /System/Library/CoreServices/Screen Sharing.app/Contents/MacOS/Screen Sharing
          40   0:05.00 /usr/libexec/replayd
        """)
    let end = ProcessListing(
      sampledNs: 10_000_000_000,
      psOutput: """
          10   0:03.00 /usr/libexec/avconferenced
          20   1:01.00 /System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer
          30   0:00.50 /System/Library/CoreServices/Screen Sharing.app/Contents/MacOS/Screen Sharing
          41   0:00.50 /System/Library/Frameworks/VideoToolbox.framework/XPCServices/VTEncoderXPCService
          42   0:00.50 /System/Library/Frameworks/VideoToolbox.framework/XPCServices/VTEncoderXPCService
        """)

    let totals = try #require(ProcessTotals(from: start, to: end) { $0.name })

    #expect(
      totals.top == [
        .init(name: "avconferenced", cpuPct: 20), .init(name: "VTEncoderXPCService", cpuPct: 10),
        .init(name: "WindowServer", cpuPct: 10),
      ])
    #expect(totals.cpuPct == 40)
  }
}
