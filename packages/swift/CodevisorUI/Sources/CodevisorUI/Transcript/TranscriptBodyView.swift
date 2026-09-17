import ACPKit
import CodevisorCore
import SwiftUI

/// Large tool bodies remain on the server. Only the selected page is resident.
public struct TranscriptBodyView: View {
  let resource: ToolDetailResource
  public init(resource: ToolDetailResource) { self.resource = resource }
  @Environment(\.transcriptController) private var controller
  @State private var field: String?
  @State private var page: ServerTranscriptBodyPage?
  @State private var loading = false
  @State private var error: String?
  @State private var requestID = UUID()

  private var selectedField: String? {
    field ?? resource.fields.first(where: { $0.name == "rawOutput" })?.name ?? resource.fields.first?.name
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if resource.fields.count > 1 {
        HStack {
          ForEach(resource.fields, id: \.name) { item in
            Button(label(for: item.name)) { field = item.name }
              .disabled(selectedField == item.name)
          }
        }
      }
      if let page {
        ScrollView([.horizontal, .vertical]) {
          Text(page.text).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 320)
        HStack {
          Button("Previous") { Task { await load(position: max(0, page.position - 1)) } }
            .disabled(loading || page.position == 0)
          Spacer()
          if loading { ProgressView().controlSize(.small) }
          Button("Next") { if let next = page.nextPosition { Task { await load(position: next) } } }
            .disabled(loading || page.nextPosition == nil)
        }
      } else if loading {
        ProgressView("Loading output…")
      }
      if let error {
        Text(error).foregroundStyle(.secondary)
        Button("Retry") { Task { await load(position: page?.position ?? 0) } }
      }
    }
    .task(id: selectedField) {
      page = nil; await load(position: 0)
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

  private func load(position: Int) async {
    guard let controller, let selectedField else { return }
    let request = UUID()
    requestID = request
    loading = true
    error = nil
    defer { if requestID == request { loading = false } }
    do {
      var result = try await controller.transcriptBodyPage(resource: resource, field: selectedField, position: position)
      if let page, page.revision != result.revision, result.position != 0 {
        result = try await controller.transcriptBodyPage(resource: resource, field: selectedField, position: 0)
      }
      try Task.checkCancellation()
      guard self.selectedField == selectedField, requestID == request else { return }
      page = result
    } catch {
      if requestID == request, !isTaskCancellation(error) { self.error = serverErrorMessage(error) }
    }
  }
}
