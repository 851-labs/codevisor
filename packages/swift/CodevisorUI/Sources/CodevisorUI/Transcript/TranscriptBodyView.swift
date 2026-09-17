import ACPKit
import CodevisorCore
import SwiftUI

/// Tool output reads as one scrollable document. Only visible storage blocks
/// fetch and retain their text; leaving a block releases its body.
public struct TranscriptBodyView: View {
  let resource: ToolDetailResource
  public init(resource: ToolDetailResource) { self.resource = resource }
  @State private var field: String?

  private var selectedField: ToolDetailResource.Field? {
    resource.fields.first(where: { $0.name == field })
      ?? resource.fields.first(where: { $0.name == "rawOutput" }) ?? resource.fields.first
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if resource.fields.count > 1 {
        HStack {
          ForEach(resource.fields, id: \.name) { item in
            Button(label(for: item.name)) { field = item.name }
              .disabled(selectedField?.name == item.name)
          }
        }
      }
      if let selectedField {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(0..<max(1, selectedField.pageCount ?? 1), id: \.self) { position in
              TranscriptBodyBlock(resource: resource, field: selectedField, position: position)
            }
          }
        }
        .frame(maxHeight: 320)
        .id("\(selectedField.name):\(selectedField.revision)")
      }
    }
  }

  private func label(for field: String) -> String {
    switch field {
    case "rawInput": "Input"
    case "rawOutput": "Output"
    case "content": "Content"
    default: field
    }
  }
}

private struct TranscriptBodyBlock: View {
  let resource: ToolDetailResource
  let field: ToolDetailResource.Field
  let position: Int
  @Environment(\.transcriptController) private var controller
  @State private var text: String?
  @State private var height: CGFloat = 24
  @State private var error: String?
  @State private var retry = 0

  var body: some View {
    Group {
      if let text {
        Text(text).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
          .onGeometryChange(for: CGFloat.self) {
            $0.size.height
          } action: {
            height = $0
          }
      } else if let error {
        HStack {
          Text(error).font(.caption).foregroundStyle(.secondary)
          Button("Retry") { retry += 1 }
        }
      } else {
        ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: height)
          .accessibilityLabel("Loading output")
      }
    }
    .task(id: retry) {
      guard let controller else { return }
      error = nil
      do {
        let page = try await controller.transcriptBodyPage(resource: resource, field: field.name, position: position)
        try Task.checkCancellation()
        text = page.text
      } catch {
        if !isTaskCancellation(error) { self.error = serverErrorMessage(error) }
      }
    }
    .onDisappear { text = nil }
  }
}
