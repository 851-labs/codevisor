import CodevisorClient
import Foundation

public struct SandboxFieldSteps: Equatable, Sendable {
  public let values: [Double]

  public init(field: ServerSandboxField, hostMaximum: Double?, keeping saved: Double?) {
    let minimum = field.min ?? field.steps?.first ?? 0
    let top = Swift.max(minimum, Self.limit(of: field, hostMaximum: hostMaximum, keeping: saved))
    let listed = (field.steps ?? []).filter { $0 >= minimum && $0 <= top }
    values = listed.last == top ? listed : listed + [top]
  }

  public func fitted(_ value: Double?) -> Double {
    guard let value else { return values[0] }
    return values.min { abs($0 - value) < abs($1 - value) } ?? value
  }

  private static func limit(of field: ServerSandboxField, hostMaximum: Double?, keeping saved: Double?) -> Double {
    let ceiling = field.max ?? .infinity
    if let hostMaximum { return Swift.min(hostMaximum, ceiling) }

    let fallback = field.fallbackMax ?? field.steps?.last ?? ceiling
    return Swift.min(Swift.max(fallback, saved ?? fallback), ceiling)
  }
}
