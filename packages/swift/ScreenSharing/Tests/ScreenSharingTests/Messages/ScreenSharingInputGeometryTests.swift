import Foundation
import Testing
@testable import ScreenSharing

struct ScreenSharingInputGeometryTests {
  @Test func systemKeysAreValidInputAndOtherHighCodesAreNot() {
    for key in ScreenSharingSystemKey.allCases {
      #expect(ScreenSharingInputEvent.key(code: key.rawValue, down: true, repeatKey: false, modifiers: 0).isValid)
    }
    #expect(ScreenSharingSystemKey.missionControl.rawValue == 160 && ScreenSharingSystemKey.apps.rawValue == 131)
    #expect(!ScreenSharingInputEvent.key(code: 127, down: true, repeatKey: false, modifiers: 0).isValid)
    #expect(!ScreenSharingInputEvent.key(code: 200, down: true, repeatKey: false, modifiers: 0).isValid)
  }

  @Test func geometryExcludesLetterboxingAndClampsOnlyAnActiveDrag() {
    func pointer(_ x: Double, _ y: Double, clamp: Bool = false) -> ScreenSharingPointer? {
      ScreenSharingVideoGeometry.pointer(
        x: x, y: y, surfaceWidth: 1000, surfaceHeight: 1000,
        videoWidth: 1920, videoHeight: 1080, clamp: clamp)
    }
    #expect(pointer(500, 500) == .init(x: 0.5, y: 0.5))
    #expect(pointer(500, 100) == nil)
    #expect(pointer(-10, 500) == nil)
    #expect(pointer(-10, 500, clamp: true) == .init(x: 0, y: 0.5))
    #expect(pointer(500, 100, clamp: true) == .init(x: 0.5, y: 0))
    #expect(
      ScreenSharingVideoGeometry.pointer(
        x: 100, y: 100, surfaceWidth: 0, surfaceHeight: 100,
        videoWidth: 100, videoHeight: 100) == nil)
  }

  @Test func geometryMapsTheVideoCornersOfAWiderSurface() {
    #expect(
      ScreenSharingVideoGeometry.pointer(
        x: 500, y: 0, surfaceWidth: 2000, surfaceHeight: 600,
        videoWidth: 1000, videoHeight: 600) == .init(x: 0, y: 0))
    #expect(
      ScreenSharingVideoGeometry.pointer(
        x: 1500, y: 600, surfaceWidth: 2000, surfaceHeight: 600,
        videoWidth: 1000, videoHeight: 600) == .init(x: 1, y: 1))
  }
}
