import ComposableArchitecture

@DependencyClient
public struct ScreenSharingSurfaceClient: Sendable {
  public var retry: @Sendable () async -> Void
  public var takePicture: @Sendable () async -> Void
  public var switchDisplay: @Sendable (_ displayId: String) async -> Void
}

extension ScreenSharingSurfaceClient: TestDependencyKey {
  public static var testValue: Self { Self() }
}

extension ScreenSharingSurfaceClient {
  public static func live(_ surface: ScreenSharingDesktopSurface) -> Self {
    Self(
      retry: { await surface.retry() }, takePicture: { await surface.takePicture() },
      switchDisplay: { await surface.switchDisplay(to: $0) })
  }
}
