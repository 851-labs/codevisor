import Foundation
import TranscriptKit
#if canImport(AppKit)
  import AppKit
#elseif canImport(UIKit)
  import UIKit
  import UniformTypeIdentifiers
#endif

@MainActor
public enum TranscriptQuotePasteboard {
  public static let typeIdentifier = "com.851labs.codevisor.quoted-prompt"

  public static func copy(_ prompt: TranscriptQuotedPrompt) {
    guard !prompt.quotes.isEmpty else { return PlatformPasteboard.copy(prompt.text) }

    write(readable: prompt.readableText, quoted: prompt.promptText)
  }

  public static func copiedPrompt() -> TranscriptQuotedPrompt? {
    quotedText().map(TranscriptQuotedPrompt.init(promptText:))
  }

  #if canImport(AppKit)
    public static let type = NSPasteboard.PasteboardType(typeIdentifier)

    private static func write(readable: String, quoted: String) {
      let pasteboard = NSPasteboard.general
      pasteboard.clearContents()
      pasteboard.setString(readable, forType: .string)
      pasteboard.setString(quoted, forType: type)
    }

    private static func quotedText() -> String? {
      NSPasteboard.general.string(forType: type)
    }
  #elseif canImport(UIKit)
    private static func write(readable: String, quoted: String) {
      UIPasteboard.general.setItems([[UTType.utf8PlainText.identifier: readable, typeIdentifier: Data(quoted.utf8)]])
    }

    private static func quotedText() -> String? {
      UIPasteboard.general.data(forPasteboardType: typeIdentifier).flatMap { String(data: $0, encoding: .utf8) }
    }
  #endif
}
