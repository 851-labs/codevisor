import Foundation

/// JSON coders configured for ACP wire format.
///
/// `JSONEncoder`/`JSONDecoder` are not safe to share across concurrent tasks,
/// and the connection encodes/decodes from multiple tasks, so fresh instances
/// are vended per access.
public enum ACPJSON {
  public static var encoder: JSONEncoder {
    let encoder = JSONEncoder()
    // ACP messages must not contain embedded newlines (stdio framing),
    // so pretty printing is never used.
    encoder.outputFormatting = [.withoutEscapingSlashes]
    return encoder
  }

  public static var decoder: JSONDecoder { JSONDecoder() }
}
