import Testing

@testable import ScreenSharing

@Suite("Scroll distance to wheel clicks on a VNC desktop")
struct VNCWheelTests {
  private func clicks(_ wheel: inout VNCWheel, _ deltas: [Int32]) -> [Int] {
    deltas.map { wheel.clicks(for: $0) }
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

  @Test("Distance left over from one touch drag is dropped when the next drag begins")
  func leftoverEndsWithTheGesture() {
    var wheel = VNCWheel(input: .touch)
    #expect(clicks(&wheel, [19]) == [0])
    wheel.gestureBegan()
    #expect(clicks(&wheel, [1, 19]) == [0, 1])
  }
}
