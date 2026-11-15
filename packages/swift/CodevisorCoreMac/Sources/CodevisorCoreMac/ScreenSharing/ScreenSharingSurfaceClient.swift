import ComposableArchitecture

@DependencyClient
public struct ScreenSharingSurfaceClient: Sendable {
  public var retry: @Sendable () async -> Void
  public var takeControl: @Sendable () async -> Void
  public var setMode: @Sendable (_ mode: ScreenSharingViewer.InteractionMode) async -> Void
  public var setDynamicResolution: @Sendable (_ enabled: Bool) async -> Void
  public var switchDisplay: @Sendable (_ displayId: String) async -> Void
}

extension ScreenSharingSurfaceClient: TestDependencyKey {
  public static var testValue: Self { Self() }
}

extension ScreenSharingSurfaceClient {
  public static func live(_ surface: ScreenSharingDesktopSurface) -> Self {
    Self(
      retry: { await surface.retry() }, takeControl: { await surface.takeControl() },
      setMode: { await surface.setMode($0) }, setDynamicResolution: { await surface.setDynamicResolution($0) },
      switchDisplay: { await surface.switchDisplay(to: $0) })
  }
}
