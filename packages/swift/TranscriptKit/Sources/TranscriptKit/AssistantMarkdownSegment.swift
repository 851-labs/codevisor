import Foundation
import MarkdownCore

public enum AssistantMarkdownSegment: Sendable, Equatable {
  case markdown(String)
  case file(PreviewFile, label: String)
}

private let assistantLinkExpression = try! NSRegularExpression(
  pattern: #"!?\[([^\]]*)\]\(\s*(?:<([^>]+)>|([^\s)]+))(?:\s+(?:"[^"]*"|'[^']*'))?\s*\)"#
)

private let attachmentOrigin = "https://attachments.codevisor.invalid/"

public func markdownAttachmentFile(_ target: String) -> PreviewFile? {
  guard target.hasPrefix(attachmentOrigin),
    let components = URLComponents(string: target),
    let name = components.queryItems?.first(where: { $0.name == "name" })?.value,
    !name.isEmpty
  else { return nil }
  let fileID = String(components.path.dropFirst())
  guard !fileID.isEmpty, !fileID.contains("/") else { return nil }
  let namedFile = PreviewFile(serverPath: name)
  return PreviewFile(
    source: .attachment(fileId: fileID), name: namedFile.name, mimeType: namedFile.mimeType, kind: namedFile.kind)
}

private struct MarkdownFence {
  public let character: Character
  public let length: Int
  public let quoteDepth: Int
  public let sourceLocation: Int
}

private struct MarkdownLine {
  public let content: String
  public let quoteDepth: Int
  public let sourceRange: NSRange
}

private func markdownLines(_ markdown: NSString) -> [MarkdownLine] {
  var result: [MarkdownLine] = []
  var location = 0
  while location < markdown.length {
    let sourceRange = markdown.lineRange(for: NSRange(location: location, length: 0))
    var contentEnd = NSMaxRange(sourceRange)
    while contentEnd > sourceRange.location {
      let character = markdown.character(at: contentEnd - 1)
      guard character == 10 || character == 13 else { break }
      contentEnd -= 1
    }
    let line = markdown.substring(
      with: NSRange(location: sourceRange.location, length: contentEnd - sourceRange.location)
    )
    let (content, quoteDepth) = markdownContainerContent(line)
    result.append(
      MarkdownLine(
        content: content,
        quoteDepth: quoteDepth,
        sourceRange: sourceRange
      ))
    location = NSMaxRange(sourceRange)
  }
  return result
}

private func markdownContainerContent(_ line: String) -> (String, Int) {
  var index = line.startIndex
  var quoteDepth = 0
  while index < line.endIndex {
    let checkpoint = index
    var spaces = 0
    while index < line.endIndex, line[index] == " ", spaces < 3 {
      spaces += 1
      index = line.index(after: index)
    }
    guard index < line.endIndex, line[index] == ">" else {
      index = checkpoint
      break
    }
    quoteDepth += 1
    index = line.index(after: index)
    if index < line.endIndex, line[index] == " " || line[index] == "\t" {
      index = line.index(after: index)
    }
  }
  return (String(line[index...]), quoteDepth)
}

private func markdownFenceRun(in line: String, closing: Bool) -> (Character, Int)? {
  var index = line.startIndex
  var spaces = 0
  while index < line.endIndex, line[index] == " ", spaces < 4 {
    spaces += 1
    index = line.index(after: index)
  }
  guard spaces <= 3, index < line.endIndex else { return nil }
  let character = line[index]
  guard character == "`" || character == "~" else { return nil }
  var length = 0
  while index < line.endIndex, line[index] == character {
    length += 1
    index = line.index(after: index)
  }
  guard length >= 3 else { return nil }
  let remainder = line[index...]
  if closing {
    guard remainder.allSatisfy({ $0 == " " || $0 == "\t" }) else { return nil }
  } else if character == "`", remainder.contains("`") {
    return nil
  }
  return (character, length)
}

private func isIndentedCode(_ line: String) -> Bool {
  guard let first = line.first else { return false }
  if first == "\t" { return true }
  return line.prefix(4).allSatisfy({ $0 == " " }) && line.count >= 4
}

private func mergedMarkdownRanges(_ ranges: [NSRange]) -> [NSRange] {
  var merged: [NSRange] = []
  for range in ranges.sorted(by: { $0.location < $1.location }) where range.length > 0 {
    guard let previous = merged.last, range.location <= NSMaxRange(previous) else {
      merged.append(range)
      continue
    }
    merged[merged.count - 1].length =
      max(NSMaxRange(previous), NSMaxRange(range))
      - previous.location
  }
  return merged
}

private func markdownBlockCodeRanges(_ markdown: NSString) -> [NSRange] {
  var ranges: [NSRange] = []
  var fence: MarkdownFence?
  for line in markdownLines(markdown) {
    if let openFence = fence, line.quoteDepth < openFence.quoteDepth {
      ranges.append(
        NSRange(
          location: openFence.sourceLocation,
          length: line.sourceRange.location - openFence.sourceLocation
        ))
      fence = nil
    }
    if let openFence = fence {
      if line.quoteDepth == openFence.quoteDepth,
        let closing = markdownFenceRun(in: line.content, closing: true),
        closing.0 == openFence.character, closing.1 >= openFence.length
      {
        ranges.append(
          NSRange(
            location: openFence.sourceLocation,
            length: NSMaxRange(line.sourceRange) - openFence.sourceLocation
          ))
        fence = nil
      }
      continue
    }
    if let opening = markdownFenceRun(in: line.content, closing: false) {
      fence = MarkdownFence(
        character: opening.0,
        length: opening.1,
        quoteDepth: line.quoteDepth,
        sourceLocation: line.sourceRange.location
      )
    } else if isIndentedCode(line.content) {
      ranges.append(line.sourceRange)
    }
  }
  if let fence {
    ranges.append(
      NSRange(
        location: fence.sourceLocation,
        length: markdown.length - fence.sourceLocation
      ))
  }
  return mergedMarkdownRanges(ranges)
}

private func markdownCodeRanges(_ markdown: String) -> [NSRange] {
  let source = markdown as NSString
  let blockRanges = markdownBlockCodeRanges(source)
  return mergedMarkdownRanges(
    blockRanges + MarkdownInlineCodeRanges.ranges(in: source, excluding: blockRanges)
  )
}

public func markdownLocalFilePath(_ target: String) -> String? {
  guard !target.hasPrefix("#") else { return nil }
  guard !target.hasPrefix("//") else { return nil }
  if target.hasPrefix("file://") { return target }
  if target.range(of: #"^[A-Za-z][A-Za-z0-9+.-]*:"#, options: .regularExpression) != nil {
    return nil
  }
  let decoded = target.removingPercentEncoding ?? target
  return decoded
}

public func assistantMarkdownSegments(
  _ markdown: String,
  attachments: [Attachment],
  includeUnreferencedAttachments: Bool = true,
  localImagesPendingCapture: Bool = false
) -> [AssistantMarkdownSegment] {
  let request = AssistantMarkdownSegmentCache.Key(
    markdown: markdown, attachments: attachments, includeUnreferencedAttachments: includeUnreferencedAttachments,
    localImagesPendingCapture: localImagesPendingCapture)
  return AssistantMarkdownSegmentCache.shared.segments(for: request) { key in
    segmentAssistantMarkdown(
      key.markdown, attachments: key.attachments, includeUnreferencedAttachments: key.includeUnreferencedAttachments,
      localImagesPendingCapture: key.localImagesPendingCapture)
  }
}

private func segmentAssistantMarkdown(
  _ markdown: String,
  attachments: [Attachment],
  includeUnreferencedAttachments: Bool,
  localImagesPendingCapture: Bool
) -> [AssistantMarkdownSegment] {
  let attachments = uniqueAttachments(attachments)
  let byID = Dictionary(uniqueKeysWithValues: attachments.map { ($0.fileId, $0) })
  var segments: [AssistantMarkdownSegment] = []
  var offset = markdown.startIndex
  let fullRange = NSRange(markdown.startIndex..<markdown.endIndex, in: markdown)
  let codeRanges = markdownCodeRanges(markdown)
  let parsed = markdown.contains("|") ? MarkdownParser().parseWithTableRanges(markdown) : nil
  var referenced = attachmentIDs(in: parsed?.blocks.flatMap(\.imageSources) ?? [], knownIDs: byID)

  for match in assistantLinkExpression.matches(in: markdown, range: fullRange) {
    guard !MarkdownInlineCodeRanges.characterIsEscaped(at: match.range.location, in: markdown as NSString),
      !codeRanges.contains(where: { NSIntersectionRange($0, match.range).length > 0 })
    else { continue }
    guard let matchRange = Range(match.range, in: markdown),
      let targetRange = [2, 3]
        .compactMap({ Range(match.range(at: $0), in: markdown) })
        .first
    else { continue }
    let target = String(markdown[targetRange])
    let isImage = markdown[matchRange.lowerBound] == "!"
    let file: PreviewFile
    if target.hasPrefix(attachmentOrigin),
      let attachment = byID[String(target.dropFirst(attachmentOrigin.count).prefix(while: { $0 != "?" }))]
    {
      file = PreviewFile(attachment: attachment)
      referenced.insert(attachment.fileId)
      if !isImage, markdownAttachmentFile(target) != nil { continue }
    } else if localImagesPendingCapture, isImage, let path = markdownLocalFilePath(target) {
      file = PreviewFile(pendingCapture: path)
    } else {
      continue
    }
    if parsed?.tableRanges.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) == true {
      continue
    }
    if offset < matchRange.lowerBound {
      segments.append(.markdown(String(markdown[offset..<matchRange.lowerBound])))
    }
    segments.append(.file(file, label: linkLabel(match, in: markdown) ?? file.name))
    offset = matchRange.upperBound
  }
  if offset < markdown.endIndex {
    segments.append(.markdown(String(markdown[offset...])))
  }
  if includeUnreferencedAttachments {
    segments += unreferencedAttachmentSegments(attachments, referenced: referenced)
  }
  return segments
}

private func uniqueAttachments(_ attachments: [Attachment]) -> [Attachment] {
  var seen = Set<String>()
  return attachments.filter { seen.insert($0.fileId).inserted }
}

private func linkLabel(_ match: NSTextCheckingResult, in markdown: String) -> String? {
  Range(match.range(at: 1), in: markdown)
    .map { String(markdown[$0]) }
    .flatMap { $0.isEmpty ? nil : $0 }
}

private func attachmentIDs(in imageSources: [String], knownIDs: [String: Attachment]) -> Set<String> {
  Set(
    imageSources
      .filter { $0.hasPrefix(attachmentOrigin) }
      .map { String($0.dropFirst(attachmentOrigin.count).prefix(while: { $0 != "?" })) }
      .filter { knownIDs[$0] != nil }
  )
}

private func unreferencedAttachmentSegments(
  _ attachments: [Attachment],
  referenced: Set<String>
) -> [AssistantMarkdownSegment] {
  attachments
    .filter { !referenced.contains($0.fileId) }
    .map { .file(PreviewFile(attachment: $0), label: $0.name) }
}
