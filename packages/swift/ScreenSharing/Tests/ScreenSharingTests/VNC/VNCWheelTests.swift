import Testing

@testable import ScreenSharing

@Suite("Scroll distance to wheel clicks on a VNC desktop")
struct VNCWheelTests {
  @Test("A mouse wheel or trackpad event is always at least one click, and at most eight")
  func wheelEventsAlwaysClick() {
    var wheel = VNCWheel(input: .wheel)
    #expect([1, 12, 45, -5, 4000, -4000].map { wheel.clicks(for: $0) } == [1, 1, 2, -1, 8, -8])
  }

  @Test("A slow touch drag clicks once per 20 pixels travelled, however many small steps it arrives in")
  func touchFollowsTheDistance() {
    var wheel = VNCWheel(input: .touch)
    let clicks = (0..<30).map { _ in wheel.clicks(for: 3) }
    #expect(clicks.reduce(0, +) == 4)
    #expect(clicks.prefix(6) == [0, 0, 0, 0, 0, 0] && clicks[6] == 1)
  }

  @Test("Turning a touch drag around first takes back the distance not yet clicked")
  func touchReverses() {
    var wheel = VNCWheel(input: .touch)
    #expect([15, -10, -30].map { wheel.clicks(for: $0) } == [0, 0, -1])
  }

  @Test("One fast touch step clicks at most eight times")
  func touchIsCapped() {
    var wheel = VNCWheel(input: .touch)
    #expect(wheel.clicks(for: 4000) == 8)
    #expect(wheel.clicks(for: -4000) == -8)
  }
}
