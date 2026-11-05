import Foundation

public protocol ServerTransportFailure: Error {
  var isConnectionLoss: Bool { get }
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
}

extension ServerRequestGateError: ServerTransportFailure {
  public var isConnectionLoss: Bool { true }
}

extension MachineUnreachableError: ServerTransportFailure {
  public var isConnectionLoss: Bool { true }
}
