import Testing

@testable import ScreenSharing

@Suite("Scroll distance to wheel clicks on a VNC desktop")
struct VNCWheelTests {
  private let start = ContinuousClock.now

  private func clicks(_ wheel: inout VNCWheel, _ deltas: [Int32], every step: Duration = .milliseconds(16)) -> [Int] {
    deltas.enumerated().map { index, delta in wheel.clicks(for: delta, at: start + step * index) }
  }

  @Test("A mouse wheel or trackpad event is always at least one click, and at most eight")
  func wheelEventsAlwaysClick() {
    var wheel = VNCWheel(input: .wheel)
    #expect(clicks(&wheel, [1, 12, 45, -5, 4000, -4000]) == [1, 1, 2, -1, 8, -8])
  }

  @Test("A slow touch drag clicks once per 20 pixels travelled, however many small steps it arrives in")
  func touchFollowsTheDistance() {
    var wheel = VNCWheel(input: .touch)
    let turned = clicks(&wheel, Array(repeating: 3, count: 30))
    #expect(turned.reduce(0, +) == 4)
    #expect(turned.prefix(6) == [0, 0, 0, 0, 0, 0] && turned[6] == 1)
  }

  @Test("Turning a touch drag around first takes back the distance not yet clicked")
  func touchReverses() {
    var wheel = VNCWheel(input: .touch)
    #expect(clicks(&wheel, [15, -10, -30]) == [0, 0, -1])
  }

  @Test("One fast touch step clicks at most eight times")
  func touchIsCapped() {
    var wheel = VNCWheel(input: .touch)
    #expect(clicks(&wheel, [4000, -4000]) == [8, -8])
  }

  @Test(
    "Distance left over from one touch drag is forgotten once the fingers have paused, so the next drag starts fresh")
  func leftoverEndsWithTheGesture() {
    var wheel = VNCWheel(input: .touch)
    let pause = VNCWheel.leftoverLifetime + .milliseconds(1)
    #expect(wheel.clicks(for: 19, at: start) == 0)
    #expect(wheel.clicks(for: 1, at: start + pause) == 0)
    #expect(wheel.clicks(for: 19, at: start + pause + .milliseconds(16)) == 1)
  }

  @Test("Within one drag, however slow its steps up to the pause, the leftover distance still counts")
  func leftoverLastsThroughTheGesture() {
    var wheel = VNCWheel(input: .touch)
    #expect(wheel.clicks(for: 19, at: start) == 0)
    #expect(wheel.clicks(for: 1, at: start + VNCWheel.leftoverLifetime) == 1)
  }
}
