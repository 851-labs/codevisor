import ACPKit

public enum CanonicalMode: String, Sendable {
  case readOnly
  case ask
  case autoEdit
  case fullAccess
  case plan
}

extension SessionMode {
  public var canonicalMode: CanonicalMode? {
    canonicalId.flatMap(CanonicalMode.init(rawValue:))
  }
}
