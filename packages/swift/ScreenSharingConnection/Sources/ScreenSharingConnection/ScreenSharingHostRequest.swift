import CodevisorClient

public struct ScreenSharingHostRequest: Sendable {
  public struct App: Equatable, Sendable {
    public let key: String
    public let name: String

    public init(key: String, name: String) {
      self.key = key
      self.name = name
    }
  }

  public static let engine = "v2"

  public var base: ServerScreenSharingRequest
  public var app: App?
  public var intent: ScreenSharingStartIntent?

  public init(_ base: ServerScreenSharingRequest, app: App? = nil, intent: ScreenSharingStartIntent? = nil) {
    self.base = base
    self.app = app
    self.intent = intent
  }
}
