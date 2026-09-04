import ACPKit
import Foundation

extension ToolCall {
  public var generatedImageAttachment: Attachment? {
    guard kind == .imageGeneration, status == .completed,
      case let .object(output) = rawOutput,
      case let .object(file) = output["attachment"],
      case let .string(fileId) = file["fileId"],
      case let .string(name) = file["name"],
      case let .string(mimeType) = file["mimeType"],
      case let .number(sizeBytes) = file["sizeBytes"],
      sizeBytes.isFinite, sizeBytes >= 0, sizeBytes < Double(Int.max)
    else { return nil }
    return Attachment(fileId: fileId, name: name, mimeType: mimeType, sizeBytes: Int(sizeBytes), kind: .image)
  }
}

extension AssistantTurn {
  /// Successful images render through the ordinary attachment preview. The
  /// remaining calls keep a visible progress or failure card above the reply.
  public var generatedImageActivity: [ToolCall] {
    toolCalls.filter { $0.kind == .imageGeneration && $0.generatedImageAttachment == nil }
  }

  mutating func receiveGeneratedImage(_ call: ToolCall) {
    guard call.parentToolCallId == nil, let image = call.generatedImageAttachment,
      !attachments.contains(where: { $0.fileId == image.fileId })
    else { return }
    attachments.append(image)
  }
}
