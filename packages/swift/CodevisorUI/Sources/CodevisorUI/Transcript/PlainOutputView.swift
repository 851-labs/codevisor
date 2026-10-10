#if canImport(AppKit)
  import AppKit
#elseif canImport(UIKit)
  import UIKit
#endif
import CodevisorCore
import StreamMarkdown
import SwiftUI

/// A diff-card-style surface for commands, logs, and other unstructured text.
/// The native implementations keep the complete value in one TextKit document,
/// so large outputs do not create a SwiftUI view per line. Long lines scroll
/// horizontally and tall output is capped to the same viewport as file diffs.
public struct PlainOutputView<Trailing: View>: View {
  private let title: String
  private let text: String
  private let emptyMessage: String?
  private let followsTail: Bool
  private let trailing: Trailing

  @Environment(\.theme) private var theme

  public init(
    title: String,
    text: String,
    emptyMessage: String? = nil,
    followsTail: Bool = false,
    @ViewBuilder trailing: () -> Trailing
  ) {
    self.title = title
    self.text = text
    self.emptyMessage = emptyMessage
    self.followsTail = followsTail
    self.trailing = trailing()
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 8) {
        Text(title)
          .font(.caption2.weight(.semibold))
          .foregroundStyle(.secondary)
          .lineLimit(1)
        Spacer(minLength: 8)
        trailing
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 6)

      Divider()

      if text.isEmpty, let emptyMessage {
        Text(emptyMessage)
          .font(.caption)
          .italic()
          .foregroundStyle(.secondary)
          .padding(.horizontal, 8)
          .padding(.vertical, 6)
          .frame(maxWidth: .infinity, alignment: .leading)
      } else {
        outputBody
      }
    }
    .background(theme.codeBackground)
    .clipShape(RoundedRectangle(cornerRadius: 8))
    .overlay {
      RoundedRectangle(cornerRadius: 8).strokeBorder(theme.border, lineWidth: 1)
    }
    .contentShape(RoundedRectangle(cornerRadius: 8))
  }

  @ViewBuilder
  private var outputBody: some View {
    #if canImport(AppKit)
      NativePlainOutputView(text: text, theme: theme, followsTail: followsTail)
        .frame(maxWidth: .infinity, alignment: .leading)
    #elseif canImport(UIKit)
      IOSNativePlainOutputView(text: text, theme: theme, followsTail: followsTail)
        .frame(maxWidth: .infinity, alignment: .leading)
    #else
      ScrollView(.horizontal, showsIndicators: true) {
        Text(text.isEmpty ? " " : text)
          .font(.system(.caption, design: .monospaced))
          .foregroundStyle(theme.textPrimary)
          .textSelection(.enabled)
          .padding(.horizontal, 8)
          .padding(.vertical, 4)
      }
      .fixedSize(horizontal: false, vertical: true)
      .scrollBounceBehavior(.basedOnSize, axes: [.horizontal])
    #endif
  }
}

extension PlainOutputView where Trailing == EmptyView {
  public init(
    title: String,
    text: String,
    emptyMessage: String? = nil,
    followsTail: Bool = false
  ) {
    self.init(
      title: title,
      text: text,
      emptyMessage: emptyMessage,
      followsTail: followsTail
    ) {
      EmptyView()
    }
  }
}

/// Plain text as a bare code block body: no header, no copy button, in the
/// diff card's capped, scrollable viewport. Given a command, it reads as a
/// terminal: the command's line first and the output under it.
struct PlainCodeBodyView: View {
  var command: String? = nil
  let output: String
  var followsTail = false

  @Environment(\.theme) private var theme

  var body: some View {
    Group {
      if command == nil, output.isEmpty {
        Text("No output")
          .font(.caption)
          .italic()
          .foregroundStyle(.secondary)
          .padding(.horizontal, 8)
          .padding(.vertical, 6)
          .frame(maxWidth: .infinity, alignment: .leading)
      } else {
        terminalBody
          .padding(.vertical, 2)
      }
    }
    .background(theme.codeBackground)
    .clipShape(RoundedRectangle(cornerRadius: 8))
    .overlay {
      RoundedRectangle(cornerRadius: 8).strokeBorder(theme.border, lineWidth: 1)
    }
    .contentShape(RoundedRectangle(cornerRadius: 8))
  }

  @ViewBuilder
  private var terminalBody: some View {
    #if canImport(AppKit)
      NativePlainOutputView(text: output, theme: theme, followsTail: followsTail, command: command)
        .frame(maxWidth: .infinity, alignment: .leading)
    #elseif canImport(UIKit)
      IOSNativePlainOutputView(text: output, theme: theme, followsTail: followsTail, command: command)
        .frame(maxWidth: .infinity, alignment: .leading)
    #else
      Text([command, output.isEmpty ? nil : output].compactMap { $0 }.joined(separator: "\n"))
        .font(.system(.caption, design: .monospaced))
        .foregroundStyle(theme.textPrimary)
        .textSelection(.enabled)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    #endif
  }
}

#Preview {
  PlainOutputView(
    title: "Output",
    text: "$ swift test\nBuilding for debugging…\nTest run passed."
  ) {
    Label("Exit 0", systemImage: "checkmark")
      .font(.caption2)
      .foregroundStyle(.green)
  }
  .padding()
  .frame(width: 520)
}
