import ACPKit

/// Codevisor's harness-independent mode vocabulary. Providers map their native
/// permission/approval modes onto these ids so Codevisor can recognize shared
/// modes (such as plan) across harnesses; modes without a mapping stay
/// native-only.
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
