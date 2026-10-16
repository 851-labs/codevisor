#if canImport(AppKit)
  import AppKit
#elseif canImport(UIKit)
  import UIKit
#endif
import CodeHighlighter
import CodevisorCore
import StreamMarkdown
import SwiftUI

public struct PlainOutputView<Trailing: View>: View {
  private let title: String
  private let text: String
  private let emptyMessage: String?
  private let followsTail: Bool
  private let trailing: Trailing

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
    .background(.quaternary.opacity(0.4))
    .clipShape(RoundedRectangle(cornerRadius: 8))
    .overlay {
      RoundedRectangle(cornerRadius: 8).strokeBorder(Color.separatorColor, lineWidth: 1)
    }
    .contentShape(RoundedRectangle(cornerRadius: 8))
  }

  @ViewBuilder
  private var outputBody: some View {
    #if canImport(AppKit)
      NativePlainOutputView(text: text, followsTail: followsTail)
        .frame(maxWidth: .infinity, alignment: .leading)
    #elseif canImport(UIKit)
      IOSNativePlainOutputView(text: text, followsTail: followsTail)
        .frame(maxWidth: .infinity, alignment: .leading)
    #else
      ScrollView(.horizontal, showsIndicators: true) {
        Text(text.isEmpty ? " " : text)
          .font(.system(.caption, design: .monospaced))
          .foregroundStyle(.primary)
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

struct PlainCodeBodyView: View {
  var command: String? = nil
  let output: String
  var followsTail = false
  var syntax: [[CodeHighlighter.Token]]? = nil

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
    .background(.quaternary.opacity(0.4))
    .clipShape(RoundedRectangle(cornerRadius: 8))
    .overlay {
      RoundedRectangle(cornerRadius: 8).strokeBorder(Color.separatorColor, lineWidth: 1)
    }
    .contentShape(RoundedRectangle(cornerRadius: 8))
  }

  @ViewBuilder
  private var terminalBody: some View {
    #if canImport(AppKit)
      NativePlainOutputView(
        text: output, followsTail: followsTail, command: command, syntax: syntax
      )
      .frame(maxWidth: .infinity, alignment: .leading)
    #elseif canImport(UIKit)
      IOSNativePlainOutputView(
        text: output, followsTail: followsTail, command: command, syntax: syntax
      )
      .frame(maxWidth: .infinity, alignment: .leading)
    #else
      Text([command, output.isEmpty ? nil : output].compactMap { $0 }.joined(separator: "\n"))
        .font(.system(.caption, design: .monospaced))
        .foregroundStyle(.primary)
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
