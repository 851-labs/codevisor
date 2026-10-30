import CodevisorCore
import CodevisorUI
import SwiftUI

struct WorkspaceInspectorTask: Identifiable {
  let id: String
  let description: String
  let symbol: String
  let startDate: Date?
  let open: (() -> Void)?

  init(_ task: BackgroundTaskInfo, open: (() -> Void)?) {
    id = task.id
    description = task.description
    symbol = BackgroundTaskPresentation.symbol(forTaskType: task.taskType)
    startDate = task.startDate
    self.open = open
  }
}

struct WorkspaceInspectorTasksSection: View {
  let tasks: [WorkspaceInspectorTask]
  @Binding var isExpanded: Bool

  var body: some View {
    WorkspaceInspectorCard(title: "Tasks", isExpanded: $isExpanded) {
      ForEach(tasks) { task in
        WorkspaceInspectorTaskRow(task: task)
      }
    }
  }
}

private struct WorkspaceInspectorTaskRow: View {
  let task: WorkspaceInspectorTask

  var body: some View {
    if let open = task.open {
      Button(action: open) {
        WorkspaceInspectorTaskLabel(task: task)
          .frame(maxWidth: .infinity, alignment: .leading)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help("Show in Chat")
    } else {
      WorkspaceInspectorTaskLabel(task: task)
    }
  }
}

private struct WorkspaceInspectorTaskLabel: View {
  let task: WorkspaceInspectorTask

  var body: some View {
    Label {
      HStack {
        Text(task.description)
          .lineLimit(1)
          .truncationMode(.tail)
        Spacer(minLength: 8)
        if let startDate = task.startDate {
          WorkspaceInspectorTaskElapsed(startDate: startDate)
        }
      }
    } icon: {
      Image(systemName: task.symbol)
        .foregroundStyle(.secondary)
        .frame(width: 20)
    }
  }
}

private struct WorkspaceInspectorTaskElapsed: View {
  let startDate: Date

  var body: some View {
    TimelineView(.periodic(from: startDate, by: 1)) { context in
      Text(BackgroundTaskPresentation.elapsed(from: startDate, to: context.date))
        .monospacedDigit()
        .foregroundStyle(.secondary)
    }
  }
}
