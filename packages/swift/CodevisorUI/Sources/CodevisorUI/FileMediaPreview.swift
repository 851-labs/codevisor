import CodevisorCore
import SwiftUI

struct FileMediaPreview: View {
  let path: String
  let client: any CodevisorServerClienting
  let size: Int
  @State private var url: URL?
  @State private var error: String?

  private static let byteLimit = 100 * 1024 * 1024

  private var name: String { FileDocumentLocation.name(path) }

  var body: some View {
    Group {
      if !FilePreviewKind.hasSystemPreview(name: name) {
        FileNoPreview(name: name)
      } else if let url {
        NativeFilePreview(url: url)
      } else if let error {
        ContentUnavailableView("Preview unavailable", systemImage: "doc", description: Text(error))
      } else {
        ProgressView("Loading preview…")
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .task(id: path) { await load() }
  }

  private func load() async {
    url = nil
    error = nil
    guard FilePreviewKind.hasSystemPreview(name: name) else { return }
    guard size <= Self.byteLimit else { return error = "This file is too large to preview here." }
    do {
      url = try await FileMaterializer.url(path: path, client: client)
    } catch {
      if !isTaskCancellation(error) { self.error = serverErrorMessage(error) }
    }
  }
}

private struct FileNoPreview: View {
  let name: String

  var body: some View {
    ContentUnavailableView {
      Label {
        Text(name)
      } icon: {
        FileIcon(path: name, size: 44)
      }
    } description: {
      Text("There is no preview for this kind of file.")
    }
  }
}

#if canImport(AppKit)
  import Quartz
  private struct NativeFilePreview: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> QLPreviewView { QLPreviewView(frame: .zero, style: .normal)! }
    func updateNSView(_ view: QLPreviewView, context: Context) { view.previewItem = url as NSURL }
  }
#else
  import QuickLook
  private struct NativeFilePreview: UIViewControllerRepresentable {
    let url: URL
    func makeCoordinator() -> Coordinator { Coordinator(url: url) }
    func makeUIViewController(context: Context) -> QLPreviewController {
      let view = QLPreviewController()
      view.dataSource = context.coordinator
      return view
    }
    func updateUIViewController(_ view: QLPreviewController, context: Context) {
      if context.coordinator.url != url { context.coordinator.url = url; view.reloadData() }
    }
    final class Coordinator: NSObject, QLPreviewControllerDataSource {
      var url: URL
      init(url: URL) { self.url = url }
      func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
      func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem {
        url as NSURL
      }
    }
  }
#endif
