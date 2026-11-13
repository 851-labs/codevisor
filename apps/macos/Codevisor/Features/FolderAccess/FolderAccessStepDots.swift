import CodevisorCore
import SwiftUI

struct FolderAccessStepDots: View {
  let folders: FirstRunFolderAccess

  var body: some View {
    if total > 1 {
      HStack(spacing: 6) {
        ForEach(0..<total, id: \.self) { step in
          Circle()
            .fill(step == folders.answered ? Color.primary.opacity(0.6) : Color.primary.opacity(0.18))
            .frame(width: 6, height: 6)
        }
      }
      .accessibilityElement()
      .accessibilityLabel("Step \(folders.answered + 1) of \(total)")
    }
  }

  private var total: Int {
    folders.answered + folders.asking.count
  }
}
