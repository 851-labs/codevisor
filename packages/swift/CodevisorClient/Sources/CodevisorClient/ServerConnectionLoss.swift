import Foundation

public protocol ServerTransportFailure: Error {
  var isConnectionLoss: Bool { get }
  var isInterruption: Bool { get }
}

extension ServerTransportFailure {
  public var isInterruption: Bool { false }
}

public enum ServerConnectionLoss {
  private static let lostConnectionCodes: Set<URLError.Code> = [
    .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
    .timedOut, .secureConnectionFailed, .cannotLoadFromNetwork, .internationalRoamingOff, .dataNotAllowed,
    .callIsActive,
  ]

  public static func isConnectionLoss(_ error: any Error) -> Bool {
    if let failure = error as? any ServerTransportFailure { return failure.isConnectionLoss }
    if let urlError = error as? URLError { return lostConnectionCodes.contains(urlError.code) }
    return (error as NSError).domain == NSPOSIXErrorDomain
  }

  public static func isInterruption(_ error: any Error) -> Bool {
    if let failure = error as? any ServerTransportFailure { return failure.isInterruption }
    return (error as? URLError)?.code == .networkConnectionLost
  }

  public static let interruptionRetryDelays: [Duration] = [.milliseconds(500), .seconds(1)]

  public static func retryingInterruptions<Value>(
    isolation: isolated (any Actor)? = #isolation,
    sleep: (Duration) async throws -> Void,
    _ operation: () async throws -> Value
  ) async throws -> Value {
    for delay in interruptionRetryDelays {
      do {
        return try await operation()
      } catch  where isInterruption(error) {
        try await sleep(delay)
      }
    }
    return try await operation()
  }
}

extension ServerRequestGateError: ServerTransportFailure {
  public var isConnectionLoss: Bool { true }
}

extension MachineUnreachableError: ServerTransportFailure {
  public var isConnectionLoss: Bool { true }
}
