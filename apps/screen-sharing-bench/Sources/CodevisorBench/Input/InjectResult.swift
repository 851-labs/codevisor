import CoreGraphics
import ScreenSharingBench

struct InjectResult: Encodable {
  struct FrontmostApp: Encodable {
    let app: String
    let events: Int
  }

  let role = "input-injector"
  let keys: Int
  let clicks: Int
  let clickTarget: String
  let frontmost: [FrontmostApp]

  @MainActor
  init(_ injection: InputInjection, target: CGPoint) {
    keys = injection.events.count { $0.kind == .key }
    clicks = injection.events.count { $0.kind == .click }
    clickTarget = "\(Int(target.x)),\(Int(target.y))"
    frontmost = injection.frontmostApps.keys.sorted().map {
      FrontmostApp(app: $0, events: injection.frontmostApps[$0] ?? 0)
    }
  }
}
