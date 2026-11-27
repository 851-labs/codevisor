import CodevisorClient
import Foundation

public enum MachineDesktopSetupStep: Equatable, Sendable {
  public struct Given: Equatable, Sendable {
    public var askedForPackages = false
    public var askedToReplaceOld = false
    public var mayReplaceOld = false
    public var mayReplaceUnmanaged = false

    public init() {}
  }

  case ask(MachineDesktopSetup.Confirmation)
  case done
  case fail(String)
  case installPackages
  case needAdministrator(String)
  case replaceOld
  case start(replacingUnmanaged: Bool)
  case waitForPackages

  public static func next(
    after status: ServerDesktopStatus, given: Given, on machine: String
  ) -> MachineDesktopSetupStep {
    if status.busy != nil { return .waitForPackages }
    if given.askedForPackages, status.failure != nil { return .fail(MachineDesktopWords.notInstalled(on: machine)) }
    if status.oldDesktop != nil { return oldDesktopStep(status, given, machine) }
    if !status.missing.isEmpty { return packagesStep(status, given, machine) }
    if status.state == .running, status.keepsRunning == true { return .done }
    if status.unmanaged == true, !given.mayReplaceUnmanaged { return .ask(.replaceUnmanaged) }

    return .start(replacingUnmanaged: status.unmanaged == true)
  }

  private static func oldDesktopStep(
    _ status: ServerDesktopStatus, _ given: Given, _ machine: String
  ) -> MachineDesktopSetupStep {
    guard given.mayReplaceOld else { return .ask(.replaceOld) }
    guard status.sudo == .passwordless else {
      return .needAdministrator(MachineDesktopWords.administratorNeeded(for: "Removing the older desktop", on: machine))
    }
    guard !given.askedToReplaceOld else { return .fail(MachineDesktopWords.oldDesktopStillRuns(on: machine)) }

    return .replaceOld
  }

  private static func packagesStep(
    _ status: ServerDesktopStatus, _ given: Given, _ machine: String
  ) -> MachineDesktopSetupStep {
    guard status.packageManager != nil else { return .fail(MachineDesktopWords.cannotInstall(status, on: machine)) }
    guard status.sudo == .passwordless else {
      return .needAdministrator(MachineDesktopWords.administratorNeeded(for: "Installing packages", on: machine))
    }
    guard !given.askedForPackages else { return .fail(MachineDesktopWords.stillMissing(on: machine)) }

    return .installPackages
  }
}
