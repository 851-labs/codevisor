import Dispatch
import VideoToolbox

enum ScreenSharingVideoToolboxWarmUp {
  private static let once: Void = {
    let factory = ScreenSharingVideoToolboxSessionFactory(
      width: 256, height: 64, framesPerSecond: 60, bitrate: 1_000_000)
    guard let session = try? factory.make() else { return }

    VTCompressionSessionInvalidate(session)
  }()

  static func start() {
    DispatchQueue.global(qos: .utility).async { once }
  }
}
