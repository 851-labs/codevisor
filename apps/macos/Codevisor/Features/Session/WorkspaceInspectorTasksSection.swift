import CodevisorClient
import CodevisorCore
import CodevisorUI
import SwiftUI

struct WorkspaceInspectorTask: Identifiable {
  struct Actions {
    var showInChat: (() -> Void)?
    var readOutput: (() async throws -> [String])?
    var stop: (() async throws -> Void)?
  }

  struct Machine: Equatable {
    let id: String
    let name: String
  }

  let id: String
  let description: String
  let symbol: String
  let command: String?
  let status: String
  let startDate: Date?
  var machine: Machine?
  let actions: Actions

  init(_ task: BackgroundTaskInfo, actions: Actions) {
    id = task.id
    description = task.description
    symbol = BackgroundTaskPresentation.symbol(forTaskType: task.taskType)
    command = task.command
    status = task.status
    startDate = task.startDate
    self.actions = actions
  }

  init(_ task: ServerRemoteExecTask, machine: Machine?, actions: Actions) {
    id = task.taskId
    description = task.description
    symbol = BackgroundTaskPresentation.symbol(forTaskType: "shell")
    command = task.command
    status = "running"
    startDate = task.startDate
    self.machine = machine
    self.actions = actions
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
  @State private var showsDetails = false

  var body: some View {
    Button {
      showsDetails = true
    } label: {
      WorkspaceInspectorTaskLabel(task: task)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help("Show Task Details")
    .popover(isPresented: $showsDetails, arrowEdge: .leading) {
      WorkspaceInspectorTaskPopover(task: task) { showsDetails = false }
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
            .foregroundStyle(.secondary)
        }
      }
    } icon: {
      if let machine = task.machine {
        MachineIconView(machineId: machine.id)
          .foregroundStyle(.secondary)
          .help("Running on \(machine.name)")
      } else {
        Image(systemName: task.symbol)
          .foregroundStyle(.secondary)
          .frame(width: 20)
      }
    }
  }
}

struct WorkspaceInspectorTaskElapsed: View {
  let startDate: Date

  var body: some View {
    TimelineView(.periodic(from: startDate, by: 1)) { context in
      Text(BackgroundTaskPresentation.elapsed(from: startDate, to: context.date))
        .monospacedDigit()
    }
  }
}

struct WorkspaceInspectorTaskMachine: View {
  let machine: WorkspaceInspectorTask.Machine

  var body: some View {
    HStack(spacing: 2) {
      MachineIconView(machineId: machine.id)
        .imageScale(.small)
      Text(machine.name)
        .lineLimit(1)
    }
    .font(.caption)
    .foregroundStyle(.secondary)
  }
}
