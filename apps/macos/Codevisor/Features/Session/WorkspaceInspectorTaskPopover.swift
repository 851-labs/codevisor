import CodevisorUI
import SwiftUI

struct WorkspaceInspectorTaskPopover: View {
  private static let width: CGFloat = 360
  private static let outputRefreshInterval: Duration = .seconds(1)

  let task: WorkspaceInspectorTask
  let dismiss: () -> Void
  @State private var isStopping = false
  @State private var stopFailed = false
  @State private var outputLines: [String] = []

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      WorkspaceInspectorTaskHeader(task: task)
      if let command = task.command {
        WorkspaceInspectorTaskCommand(command: command)
      }
      WorkspaceInspectorTaskStatus(task: task, isStopping: isStopping, stopFailed: stopFailed)
      if !outputLines.isEmpty {
        WorkspaceInspectorTaskOutput(lines: outputLines)
      }
      actions
    }
    .padding(14)
    .frame(width: Self.width, alignment: .leading)
    .task(id: task.actions.readOutput != nil) { await followOutput() }
  }

  private func followOutput() async {
    guard let read = task.actions.readOutput else { return }

    while !Task.isCancelled {
      if let latest = try? await read() { outputLines = latest }
      do { try await Task.sleep(for: Self.outputRefreshInterval) } catch { return }
    }
  }

  private var actions: some View {
    HStack {
      if let showInChat = task.actions.showInChat {
        Button("Show in Chat") {
          dismiss()
          showInChat()
        }
      }
      Spacer(minLength: 0)
      if let stop = task.actions.stop {
        Button("Stop", role: .destructive) { requestStop(stop) }
          .disabled(isStopping)
      }
    }
    .controlSize(.small)
  }

  private func requestStop(_ stop: @escaping () async throws -> Void) {
    isStopping = true
    stopFailed = false
    Task {
      do {
        try await stop()
      } catch {
        isStopping = false
        stopFailed = true
      }
    }
  }
}

private struct WorkspaceInspectorTaskHeader: View {
  let task: WorkspaceInspectorTask

  var body: some View {
    Label {
      Text(task.description)
        .font(.headline)
        .lineLimit(2)
    } icon: {
      Image(systemName: task.symbol)
        .foregroundStyle(.secondary)
    }
  }
}

private struct WorkspaceInspectorTaskCommand: View {
  let command: String

  var body: some View {
    Text(command)
      .font(.system(.callout, design: .monospaced))
      .foregroundStyle(.secondary)
      .lineLimit(4)
      .textSelection(.enabled)
  }
}

private struct WorkspaceInspectorTaskStatus: View {
  let task: WorkspaceInspectorTask
  let isStopping: Bool
  let stopFailed: Bool

  private var title: String {
    if stopFailed { return "Couldn't stop" }
    if isStopping { return "Stopping…" }
    return BackgroundTaskPresentation.statusTitle(task.status)
  }

  var body: some View {
    HStack(spacing: 6) {
      Text(title)
      if let startDate = task.startDate {
        Text("·")
        WorkspaceInspectorTaskElapsed(startDate: startDate)
      }
    }
    .font(.callout)
    .foregroundStyle(stopFailed ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
  }
}
