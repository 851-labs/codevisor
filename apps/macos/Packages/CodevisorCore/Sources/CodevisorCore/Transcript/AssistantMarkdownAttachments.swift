import Foundation

public enum AssistantMarkdownSegment: Sendable, Equatable {
    case markdown(String)
    case attachment(Attachment, label: String)
}

private let assistantAttachmentExpression = try! NSRegularExpression(
    pattern: #"!?\[([^\]]*)\]\(\s*<?https://attachments\.codevisor\.invalid/([A-Za-z0-9-]+)>?(?:\s+(?:"[^"]*"|'[^']*'))?\s*\)"#
)

/// Resolves only server-issued attachment URLs. Other Markdown stays intact,
/// including ordinary web links and source-navigation paths.
public func assistantMarkdownSegments(
    _ markdown: String,
    attachments: [Attachment]
) -> [AssistantMarkdownSegment] {
    let byID = Dictionary(uniqueKeysWithValues: attachments.map { ($0.fileId, $0) })
    var referenced = Set<String>()
    var segments: [AssistantMarkdownSegment] = []
    var offset = markdown.startIndex
    let fullRange = NSRange(markdown.startIndex..<markdown.endIndex, in: markdown)

    for match in assistantAttachmentExpression.matches(in: markdown, range: fullRange) {
        guard let matchRange = Range(match.range, in: markdown),
              let idRange = Range(match.range(at: 2), in: markdown),
              let attachment = byID[String(markdown[idRange])]
        else { continue }
        if offset < matchRange.lowerBound {
            segments.append(.markdown(String(markdown[offset..<matchRange.lowerBound])))
        }
        let label = Range(match.range(at: 1), in: markdown)
            .map { String(markdown[$0]) }
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? attachment.name
        segments.append(.attachment(attachment, label: label))
        referenced.insert(attachment.fileId)
        offset = matchRange.upperBound
    }
    if offset < markdown.endIndex {
        segments.append(.markdown(String(markdown[offset...])))
    }
    for attachment in attachments where !referenced.contains(attachment.fileId) {
        segments.append(.attachment(attachment, label: attachment.name))
    }
    return segments
}
