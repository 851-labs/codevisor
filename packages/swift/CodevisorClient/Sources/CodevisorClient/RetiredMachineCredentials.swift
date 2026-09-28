import Foundation

/// Bearer tokens that directly paired machines (retired: every remote
/// machine now comes from Codevisor Cloud) left in the Keychain, one item per
/// machine id under `KeychainCredentialServices.machine`. Only the move of
/// those machines onto the cloud account reads them — to reach each machine
/// one last time — and it deletes each once that machine is settled.
public enum RetiredMachineCredentials {
  public static func token(forMachineID id: String) throws -> String? {
    try KeychainValueStore(service: KeychainCredentialServices.machine).value(forAccount: id)
  }

  public static func removeToken(forMachineID id: String) throws {
    try KeychainValueStore(service: KeychainCredentialServices.machine).removeValue(forAccount: id)
  }
}
