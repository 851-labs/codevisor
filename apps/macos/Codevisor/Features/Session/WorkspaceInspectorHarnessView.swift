import ACPKit
import CodevisorCore
import SwiftUI

struct WorkspaceInspectorHarnessView: View {
  let chat: ChatSession?
  let model: WorkspaceInspectorHarnessModel
  let chatUsage: SessionUsage?
  @Binding var isUsageExpanded: Bool
  @Binding var isContextExpanded: Bool

  var body: some View {
    if let snapshot {
      ScrollView {
        VStack(alignment: .leading, spacing: 10) {
          if let limits = snapshot.limits {
            WorkspaceInspectorUsageSection(limits: limits, isExpanded: $isUsageExpanded)
          }
          WorkspaceInspectorContextSection(
            context: snapshot.context, usage: summaryUsage(of: snapshot), isExpanded: $isContextExpanded)
        }
        .padding(.vertical, 10)
      }
    } else if chat != nil {
      WorkspaceInspectorHarnessLoading()
    }
  }

  private var snapshot: WorkspaceInspectorHarnessModel.Snapshot? {
    chat.flatMap(model.snapshot(for:))
  }

  private func summaryUsage(of snapshot: WorkspaceInspectorHarnessModel.Snapshot) -> SessionUsage? {
    snapshot.chatId == chat?.id ? chatUsage : nil
  }
}

private struct WorkspaceInspectorHarnessLoading: View {
  @State private var isSlow = false

  var body: some View {
    ZStack {
      if isSlow {
        ProgressView()
          .controlSize(.small)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .task {
      guard (try? await Task.sleep(for: WorkspaceInspectorFileTreeModel.slowDelay)) != nil else { return }
      isSlow = true
    }
  }
}
