import Foundation

public enum AssistantMarkdownSegment: Sendable, Equatable {
    case markdown(String)
    case file(PreviewFile, label: String)
}

private let assistantLinkExpression = try! NSRegularExpression(
    pattern: #"!?\[([^\]]*)\]\(\s*(?:<([^>]+)>|([^\s)]+))(?:\s+(?:"[^"]*"|'[^']*'))?\s*\)"#
)

private let attachmentOrigin = "https://attachments.codevisor.invalid/"

private func localServerPath(_ target: String) -> String? {
    guard !target.hasPrefix("#") else { return nil }
    if target.hasPrefix("file://") { return target }
    if target.range(of: #"^[A-Za-z][A-Za-z0-9+.-]*:"#, options: .regularExpression) != nil {
        return nil
    }
    let decoded = target.removingPercentEncoding ?? target
    if decoded.hasPrefix("/") || decoded.hasPrefix("./") || decoded.hasPrefix("../")
        || decoded.hasPrefix("~/") {
        return decoded
    }
    // A transcript has no useful browser-relative navigation context, so a
    // scheme-less Markdown destination is a server-local path. This also
    // covers extensionless files such as README and Makefile.
    return decoded
}

/// Resolves server-issued attachment URLs and, once a turn is complete, local
/// file links. Relative paths stay relative so the server can resolve them
/// against the session's authoritative cwd.
public func assistantMarkdownSegments(
    _ markdown: String,
    attachments: [Attachment],
    includeServerPaths: Bool = true
) -> [AssistantMarkdownSegment] {
    let byID = Dictionary(uniqueKeysWithValues: attachments.map { ($0.fileId, $0) })
    var referenced = Set<String>()
    var segments: [AssistantMarkdownSegment] = []
    var offset = markdown.startIndex
    let fullRange = NSRange(markdown.startIndex..<markdown.endIndex, in: markdown)

    for match in assistantLinkExpression.matches(in: markdown, range: fullRange) {
        guard let matchRange = Range(match.range, in: markdown),
              let targetRange = [2, 3]
                .compactMap({ Range(match.range(at: $0), in: markdown) })
                .first
        else { continue }
        let target = String(markdown[targetRange])
        let file: PreviewFile
        if target.hasPrefix(attachmentOrigin),
           let attachment = byID[String(target.dropFirst(attachmentOrigin.count))] {
            file = PreviewFile(attachment: attachment)
            referenced.insert(attachment.fileId)
        } else if includeServerPaths, let path = localServerPath(target) {
            file = PreviewFile(serverPath: path)
        } else {
            continue
        }
        if offset < matchRange.lowerBound {
            segments.append(.markdown(String(markdown[offset..<matchRange.lowerBound])))
        }
        let label = Range(match.range(at: 1), in: markdown)
            .map { String(markdown[$0]) }
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? file.name
        segments.append(.file(file, label: label))
        offset = matchRange.upperBound
    }
    if offset < markdown.endIndex {
        segments.append(.markdown(String(markdown[offset...])))
    }
    for attachment in attachments where !referenced.contains(attachment.fileId) {
        segments.append(.file(PreviewFile(attachment: attachment), label: attachment.name))
    }
    return segments
}
