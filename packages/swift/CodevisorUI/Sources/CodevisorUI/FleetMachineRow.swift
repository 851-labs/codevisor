import CodevisorCore
import SwiftUI

/// One machine under a fleet entry: its name, then — when there is exactly
/// one thing to do about its status — that action, and a mark only when
/// there is something to report. Marks trail so they line up down the list
/// whether or not a row has an action; the mark's tooltip says what, and a
/// mark with a failure behind it opens that failure when clicked.
public struct FleetMachineRow<Trailing: View>: View {
  private let name: String
  private let status: FleetRowStatus
  private let details: FleetBlockedMachine?
  private let trailing: Trailing

  /// - Parameter details: the failure this row's mark opens. Nil leaves the
  ///   mark as a plain indicator.
  public init(
    name: String,
    status: FleetRowStatus,
    details: FleetBlockedMachine? = nil,
    @ViewBuilder trailing: () -> Trailing
  ) {
    self.name = name
    self.status = status
    self.details = details
    self.trailing = trailing()
  }

  public var body: some View {
    HStack(spacing: 10) {
      Text(name)
        .lineLimit(1)
        .layoutPriority(1)
      Spacer(minLength: 8)
      trailing
      #if os(macOS)
        FleetStatusMark(status: status, details: details)
          .frame(width: FleetRowMetrics.trailingControlWidth)
      #else
        FleetStatusMark(status: status, details: details)
      #endif
    }
    .frame(minHeight: FleetRowMetrics.minContentHeight)
    .padding(.vertical, 4)
    .padding(.leading, FleetRowMetrics.iconColumnWidth)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("\(name), \(status.label)")
  }
}

public extension FleetMachineRow where Trailing == EmptyView {
  init(name: String, status: FleetRowStatus, details: FleetBlockedMachine? = nil) {
    self.init(name: name, status: status, details: details) { EmptyView() }
  }
}

/// A check once a machine is in sync; a spinner while it catches up with
/// the fleet; a mark when it needs the user. Quiet states — off here,
/// unreachable, unsupported — render nothing: they are facts, not problems,
/// and a column of grey dashes would only add noise to a converged fleet.
///
/// When the status carries a failure the mark IS the way in: a second
/// "Details…" button beside it would be one control too many for a row
/// whose whole job is to stay quiet.
public struct FleetStatusMark: View {
  @Environment(\.theme) private var theme
  private let status: FleetRowStatus
  private let details: FleetBlockedMachine?
  @State private var presented: FleetBlockedMachine?

  public init(status: FleetRowStatus, details: FleetBlockedMachine? = nil) {
    self.status = status
    self.details = details
  }

  public var body: some View {
    switch status.emphasis {
    case .ready:
      mark("checkmark.circle.fill", theme.statusOK)
    case .busy:
      ProgressView().controlSize(.small)
        .help(status.label)
    case .attention:
      if let details {
        Button {
          presented = details
        } label: {
          Image(systemName: "exclamationmark.circle.fill")
            .foregroundStyle(theme.statusWarn)
        }
        .buttonStyle(.plain)
        .help(helpText)
        .accessibilityLabel("\(status.label). Show details")
        .fleetBlockedDetails(item: $presented)
      } else {
        mark("exclamationmark.circle.fill", theme.statusWarn)
      }
    case .quiet:
      EmptyView()
    }
  }

  private func mark(_ systemName: String, _ style: Color) -> some View {
    Image(systemName: systemName)
      .foregroundStyle(style)
      .help(helpText)
      .accessibilityLabel(status.label)
  }

  /// The tooltip says the failure itself when there is one — the label
  /// ("Needs attention") is only useful as a fallback.
  private var helpText: String {
    guard let reason = status.reason, !reason.isEmpty else { return status.label }
    return reason
  }
}
