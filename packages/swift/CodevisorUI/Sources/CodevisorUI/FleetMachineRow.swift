import CodevisorCore
import SwiftUI

public struct FleetMachineRow<Trailing: View>: View {
  private let machineId: String
  private let name: String
  private let status: FleetRowStatus
  private let details: FleetBlockedMachine?
  private let leadingInset: CGFloat
  private let trailing: Trailing

  public init(
    machineId: String,
    name: String,
    status: FleetRowStatus,
    details: FleetBlockedMachine? = nil,
    leadingInset: CGFloat = FleetRowMetrics.iconColumnWidth,
    @ViewBuilder trailing: () -> Trailing
  ) {
    self.machineId = machineId
    self.name = name
    self.status = status
    self.details = details
    self.leadingInset = leadingInset
    self.trailing = trailing()
  }

  public var body: some View {
    HStack(spacing: 10) {
      MachineIconView(machineId: machineId)
      Text(name)
        .lineLimit(1)
        .layoutPriority(1)
      Spacer(minLength: 8)
      trailing
      FleetStatusMark(status: status, details: details)
        .frame(width: FleetRowMetrics.trailingControlWidth)
    }
    .frame(minHeight: FleetRowMetrics.minContentHeight)
    .padding(.vertical, 4)
    .padding(.leading, leadingInset)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("\(name), \(status.label)")
  }
}

public extension FleetMachineRow where Trailing == EmptyView {
  init(machineId: String, name: String, status: FleetRowStatus, details: FleetBlockedMachine? = nil) {
    self.init(machineId: machineId, name: name, status: status, details: details) { EmptyView() }
  }
}

public struct FleetStatusMark: View {
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
      mark("checkmark.circle.fill", .green)
    case .busy:
      ProgressView().controlSize(.small)
        .help(status.label)
    case .attention:
      if let details {
        Button {
          presented = details
        } label: {
          Image(systemName: "exclamationmark.circle.fill")
            .foregroundStyle(.orange)
        }
        .buttonStyle(.plain)
        .help(helpText)
        .accessibilityLabel("\(status.label). Show details")
        .fleetBlockedDetails(item: $presented)
      } else {
        mark("exclamationmark.circle.fill", .orange)
      }
    case .quiet:
      mark("circle.fill", Color.tertiaryLabelColor.opacity(0.5))
    }
  }

  private func mark(_ systemName: String, _ style: Color) -> some View {
    Image(systemName: systemName)
      .foregroundStyle(style)
      .help(helpText)
      .accessibilityLabel(status.label)
  }

  private var helpText: String {
    guard let reason = status.reason, !reason.isEmpty else { return status.label }
    return reason
  }
}
