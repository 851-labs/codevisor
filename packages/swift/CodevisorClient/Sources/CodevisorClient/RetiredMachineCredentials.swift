import Foundation

public enum RetiredMachineCredentials {
  public static func token(forMachineID id: String) throws -> String? {
    try KeychainValueStore(service: KeychainCredentialServices.machine).value(forAccount: id)
  }

  public static func removeToken(forMachineID id: String) throws {
    try KeychainValueStore(service: KeychainCredentialServices.machine).removeValue(forAccount: id)
  }
}
