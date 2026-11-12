import Foundation
import SwiftUI

public enum SidebarRowStatus: Equatable, Sendable {
  case input(askingWorkspaceID: UUID)
  case approval(askingWorkspaceID: UUID)
  case settingUp
  case working(since: Date?)
  case waiting
  case failed
  case limited

  public var askingWorkspaceID: UUID? {
    switch self {
    case let .input(id), let .approval(id): id
    case .settingUp, .working, .waiting, .failed, .limited: nil
    }
  }

  public var workingSince: Date? {
    guard case let .working(since) = self else { return nil }
    return since
  }

  public var title: String {
    switch self {
    case .input: "Input"
    case .approval: "Approval"
    case .settingUp: "Setting up"
    case .working: "Working"
    case .waiting: "Waiting"
    case .failed: "Failed"
    case .limited: "Limited"
    }
  }

  public var systemImage: String {
    switch self {
    case .input: "questionmark.bubble.fill"
    case .approval: "hand.raised.fill"
    case .settingUp: "hammer.fill"
    case .working: "bolt.fill"
    case .waiting: "hourglass"
    case .failed: "exclamationmark.triangle.fill"
    case .limited: "gauge.with.dots.needle.100percent"
    }
  }

  public var tone: Tone {
    switch self {
    case .input, .approval, .limited: .attention
    case .working: .active
    case .settingUp, .waiting: .quiet
    case .failed: .failure
    }
  }

  public var color: Color {
    switch tone {
    case .attention: .orange
    case .active: .blue
    case .quiet: .secondary
    case .failure: .red
    }
  }

  public func replacesLeadingIcon(isUnread: Bool) -> Bool {
    switch self {
    case .input, .approval, .failed, .limited: true
    case .waiting: !isUnread
    case .working, .settingUp: false
    }
  }

  public enum Tone: Sendable {
    case attention
    case active
    case quiet
    case failure
  }

  public static func elapsed(from start: Date, to now: Date) -> String {
    let seconds = max(0, Int(now.timeIntervalSince(start)))
    if seconds < 60 { return "\(seconds)s" }
    let minutes = seconds / 60
    if minutes < 60 { return "\(minutes)m" }
    return "\(minutes / 60)h \(minutes % 60)m"
  }
}
