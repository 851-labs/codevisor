import CodevisorCore
import CodevisorUI
import StreamMarkdown
import SwiftUI
import UIKit

struct NativeTranscriptView: UIViewControllerRepresentable {
  let presentationSurface: TranscriptPresentationSurface
  let input: TranscriptSurfaceInput
  let callbacks: TranscriptSurfaceCallbacks

  func makeUIViewController(context _: Context) -> TranscriptContainerViewController {
    let container = TranscriptContainerViewController()
    let controller = container.attach(presentationSurface)
    controller.configure(input, callbacks: callbacks)
    return container
  }

  func updateUIViewController(
    _ container: TranscriptContainerViewController,
    context _: Context,
  ) {
    container.attach(presentationSurface).configure(input, callbacks: callbacks)
  }

  static func dismantleUIViewController(
    _ container: TranscriptContainerViewController,
    coordinator _: Void,
  ) {
    container.releaseSurface()
  }
}
