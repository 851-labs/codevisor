import CodevisorCore
import CryptoKit
import SwiftUI

struct FileMediaPreview: View {
  let path: String
  let client: any CodevisorServerClienting
  let size: Int
  @State private var url: URL?
  @State private var error: String?

  var body: some View {
    Group {
      if let url {
        NativeFilePreview(url: url)
      } else if let error {
        ContentUnavailableView("Preview unavailable", systemImage: "doc", description: Text(error))
      } else {
        ProgressView("Loading preview…")
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .task(id: path) {
      url = nil; error = nil
      guard size <= 100 * 1024 * 1024 else { error = "This file is too large to preview here."; return }
      do {
        let bytes = try await FileDocumentLocation.data(path: path, client: client)
        try Task.checkCancellation()
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CodevisorFilePreview/\(hash)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent(FileDocumentLocation.name(path))
        try bytes.write(to: target, options: .atomic)
        url = target
      } catch { if !isTaskCancellation(error) { self.error = serverErrorMessage(error) } }
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
