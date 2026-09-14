import SwiftUI
import CodevisorCore

#if DEBUG
  #Preview("Empty state composer") {
    ComposerCard(controller: .preview())
      .padding()
      .frame(width: 640)
  }

  #Preview("Connected composer") {
    ComposerCard(controller: .preview(model: .preview()))
      .padding()
      .frame(width: 640)
  }
#endif
