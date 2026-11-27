import Foundation

public struct ServerDesktopStatus: Decodable, Equatable, Sendable {
  public enum State: String, Decodable, Sendable {
    case none, running, stopped, outdated
  }

  public enum Sudo: String, Decodable, Sendable {
    case passwordless, password, none
  }

  public struct OldDesktop: Decodable, Equatable, Sendable {
    public var units: [String]

    public init(units: [String]) {
      self.units = units
    }
  }

  public var state: State
  public var account: String
  public var system: String
  public var problem: String?
  public var unmanaged: Bool?
  public var keepsRunning: Bool?
  public var unitOwnedByAnother: Bool?
  public var busy: String?
  public var failure: String?
  public var missing: [String]
  public var packageManager: String?
  public var sudo: Sudo?
  public var oldDesktop: OldDesktop?
  public var logHint: String
  public var setupCommand: String?

  public init(
    state: State,
    account: String = "codevisor",
    system: String = "Linux",
    problem: String? = nil,
    unmanaged: Bool? = nil,
    keepsRunning: Bool? = nil,
    unitOwnedByAnother: Bool? = nil,
    busy: String? = nil,
    failure: String? = nil,
    missing: [String] = [],
    packageManager: String? = nil,
    sudo: Sudo? = nil,
    oldDesktop: OldDesktop? = nil,
    logHint: String = "",
    setupCommand: String? = nil
  ) {
    self.state = state
    self.account = account
    self.system = system
    self.problem = problem
    self.unmanaged = unmanaged
    self.keepsRunning = keepsRunning
    self.unitOwnedByAnother = unitOwnedByAnother
    self.busy = busy
    self.failure = failure
    self.missing = missing
    self.packageManager = packageManager
    self.sudo = sudo
    self.oldDesktop = oldDesktop
    self.logHint = logHint
    self.setupCommand = setupCommand
  }
}
