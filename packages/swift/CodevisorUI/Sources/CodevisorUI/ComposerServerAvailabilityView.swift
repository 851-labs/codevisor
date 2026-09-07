import CodevisorCore
import SwiftUI

/// Connection status belongs beside a draft, so its editor and machine
/// picker stay available even when the current target cannot be reached.
public struct ComposerServerAvailabilityView: View {
  let availability: ServerAvailability
  let machineName: String
  let retry: () -> Void

  public init(
    availability: ServerAvailability,
    machineName: String,
    retry: @escaping () -> Void
  ) {
    self.availability = availability
    self.machineName = machineName
    self.retry = retry
  }

  public var body: some View {
    if availability != .ready {
      HStack(spacing: 8) {
        if case .failed = availability {
          Image(systemName: "exclamationmark.circle")
        } else {
          ProgressView().controlSize(.small)
        }
        Text(message)
          .fixedSize(horizontal: false, vertical: true)
        Spacer(minLength: 0)
        if canRetry {
          Button("Retry", action: retry)
        }
      }
      .font(.footnote)
      .foregroundStyle(.secondary)
      .accessibilityElement(children: .contain)
    }
  }

  private var message: String {
    switch availability {
    case .ready: ""
    case .failed: "Unable to connect to \(machineName)."
    case .waiting(.starting): "Starting \(machineName)…"
    case .waiting(.connecting): "Connecting to \(machineName)…"
    case .waiting(.updating): "Updating \(machineName)…"
    case .waiting(.restarting): "Restarting \(machineName)…"
    }
  }

  private var canRetry: Bool {
    switch availability {
    case .failed, .waiting(.connecting): true
    default: false
    }
  }
}
