import Foundation

public enum DiagnosticsScrubber {
  public static let maxLength = 1_000

  public static func scrub(_ text: String) -> String {
    let scrubbed = patterns.reduce(text) { partial, pattern in
      pattern.expression.stringByReplacingMatches(
        in: partial,
        range: NSRange(partial.startIndex..., in: partial),
        withTemplate: pattern.template
      )
    }
    return String(replacingUserNames(in: scrubbed).prefix(maxLength))
  }

  private struct Pattern {
    let expression: NSRegularExpression
    let template: String

    init(_ pattern: String, _ template: String, options: NSRegularExpression.Options = []) {
      expression = try! NSRegularExpression(pattern: pattern, options: options)
      self.template = template
    }
  }

  private static let patterns: [Pattern] = [
    Pattern(#"(?<![\w:/.~])~?/(?:[^\s/"'`:,;()\[\]<>]+/)+[^\s/"'`:,;()\[\]<>]*"#, "<path>"),
    Pattern(#"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#, "<email>"),
    Pattern(#"\bsk-ant-[\w-]+"#, "<redacted>"),
    Pattern(#"\b(sk|pk|rk)-[A-Za-z0-9_-]{16,}"#, "<redacted>"),
    Pattern(#"\bgh[pousr]_[A-Za-z0-9]{16,}"#, "<redacted>"),
    Pattern(#"\bgithub_pat_[A-Za-z0-9_]{16,}"#, "<redacted>"),
    Pattern(#"\bxox[abprs]-[A-Za-z0-9-]+"#, "<redacted>"),
    Pattern(#"\beyJ[\w-]+\.[\w-]+\.[\w-]+"#, "<redacted>"),
    Pattern(#"\b(Bearer|Basic)\s+[\w.~+/=-]+"#, "$1 <redacted>", options: .caseInsensitive),
    Pattern(#"\b([a-z][a-z0-9+.-]*://)[^\s/@]+@"#, "$1<redacted>@", options: .caseInsensitive),
    Pattern(
      #"\b([\w-]*(?:token|api[_-]?key|secret|password|authorization|cookie)[\w-]*)(["']?\s*[:=]\s*["']?)[^\s"',}]+"#,
      "$1$2<redacted>",
      options: .caseInsensitive
    ),
  ]

  private static let minimumNameLength = 3

  private static func replacingUserNames(in text: String) -> String {
    userNames.reduce(text) { partial, name in
      partial.replacingOccurrences(of: name, with: "<user>", options: .caseInsensitive)
    }
  }

  private static let userNames: [String] = {
    let candidates = [NSUserName(), NSFullUserName()]
    return candidates.filter { $0.count >= minimumNameLength }.sorted { $0.count > $1.count }
  }()
}
