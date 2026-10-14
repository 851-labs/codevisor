import Foundation
import Observation

@MainActor
@Observable
public final class ToolGroupDisclosure {
  public private(set) var isExpanded = false

  public func userToggled() {
    isExpanded.toggle()
  }
}

@MainActor
@Observable
public final class TranscriptDisclosureStore {
  public enum Key: Hashable, Sendable {
    case turn(UUID)
    case turnImplementation(UUID)
    case toolCall(String)
  }

  private var values: [Key: Bool] = [:]
  public private(set) var workedSectionRevision: UInt64 = 0
  @ObservationIgnored private var toolGroupDisclosures: [String: ToolGroupDisclosure] = [:]
  public init() {}

  public static let previews = TranscriptDisclosureStore()

  public func isExpanded(_ key: Key, default defaultValue: Bool) -> Bool {
    values[key] ?? defaultValue
  }

  public func setExpanded(_ key: Key, _ expanded: Bool) {
    guard values[key] != expanded else { return }
    values[key] = expanded
    advanceWorkedSectionRevisionIfNeeded(for: key)
  }

  public func toggle(_ key: Key, default defaultValue: Bool) {
    values[key] = !(values[key] ?? defaultValue)
    advanceWorkedSectionRevisionIfNeeded(for: key)
  }

  public func toolGroupDisclosure(id: String) -> ToolGroupDisclosure {
    if let disclosure = toolGroupDisclosures[id] {
      return disclosure
    }
    let disclosure = ToolGroupDisclosure()
    toolGroupDisclosures[id] = disclosure
    return disclosure
  }

  private func advanceWorkedSectionRevisionIfNeeded(for key: Key) {
    switch key {
    case .turn, .turnImplementation:
      workedSectionRevision &+= 1
    case .toolCall:
      break
    }
  }

}
