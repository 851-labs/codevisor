import Foundation

/// Why a device-approval (RFC 8628 verification) request didn't go through.
public enum CloudDeviceApprovalError: Error, Equatable, Sendable, LocalizedError {
  case invalidCode
  case expiredCode
  case alreadyProcessed
  /// Another signed-in account opened this code first.
  case claimedByAnotherAccount
  /// The link came from a cloud other than the account's own server.
  case differentServer(machineHost: String, accountHost: String)
  case signInRequired

  public var errorDescription: String? {
    switch self {
    case .invalidCode:
      "That code wasn't recognized. Run “codevisor auth login” on the machine again to get a new one."
    case .expiredCode:
      "This code has expired. Run “codevisor auth login” on the machine again to get a new one."
    case .alreadyProcessed:
      "This code was already used. If the machine isn't connected, run “codevisor auth login” on it again."
    case .claimedByAnotherAccount:
      "This code is being approved by a different Codevisor account."
    case let .differentServer(machineHost, accountHost):
      """
      This machine is connecting to a different Codevisor Cloud (\(machineHost)), but you're signed in to \
      \(accountHost). Approve it from a browser signed in to \(machineHost), or switch servers in Account \
      settings.
      """
    case .signInRequired:
      "Sign in to Codevisor Cloud to approve this machine."
    }
  }
}

extension CloudAccountClient {
  public func approveDevice(userCode: String, token: String) async throws {
    try await respondToDevice(userCode: userCode, decision: "approve", token: token)
  }

  public func denyDevice(userCode: String, token: String) async throws {
    try await respondToDevice(userCode: userCode, decision: "deny", token: token)
  }

  /// better-auth only lets the session that claimed a code act on it, so
  /// the code is claimed (`GET /device`) before it is approved or denied.
  private func respondToDevice(userCode: String, decision: String, token: String) async throws {
    var allowed = CharacterSet.urlQueryAllowed
    allowed.remove(charactersIn: "&=+#?")
    let query = userCode.addingPercentEncoding(withAllowedCharacters: allowed) ?? userCode
    let (claim, _) = try await perform("/api/auth/device?user_code=\(query)", token: token)
    struct ClaimBody: Decodable { var status: String? }
    if let status = (try? JSONDecoder().decode(ClaimBody.self, from: claim))?.status, status != "pending" {
      throw CloudDeviceApprovalError.alreadyProcessed
    }
    _ = try await perform(
      "/api/auth/device/\(decision)",
      method: "POST",
      body: JSONEncoder().encode(["userCode": userCode]),
      token: token
    )
  }

  /// Maps the device plugin's OAuth-style errors (`error`,
  /// `error_description`) to messages that say what to do next. Returns
  /// nil for failures the generic HTTP handling words better (401, 429).
  static func deviceApprovalError(status: Int, body: Data) -> CloudDeviceApprovalError? {
    struct ErrorBody: Decodable {
      var error: String?
      var errorDescription: String?
      var message: String?

      enum CodingKeys: String, CodingKey {
        case error
        case errorDescription = "error_description"
        case message
      }
    }
    guard status == 400 || status == 403 || status == 404,
      let decoded = try? JSONDecoder().decode(ErrorBody.self, from: body)
    else { return nil }
    let description = (decoded.errorDescription ?? decoded.message ?? "").lowercased()
    switch decoded.error {
    case "expired_token": return .expiredCode
    case "access_denied": return .claimedByAnotherAccount
    case "device_code_already_processed": return .alreadyProcessed
    default: break
    }
    if description.contains("already processed") { return .alreadyProcessed }
    if description.contains("expired") { return .expiredCode }
    if description.contains("invalid user code") { return .invalidCode }
    return nil
  }
}

extension CloudAccountController {
  /// Why a device-approval link can't be approved from this account, when
  /// it came from a cloud other than the account's own server. The
  /// approval carries the account's session token, so it is only ever sent
  /// to that same origin.
  public func deviceApprovalServerMismatch(for link: CloudDeviceApprovalLink) -> CloudDeviceApprovalError? {
    guard !CloudDeviceApprovalLink.sameOrigin(link.serverURL, serverURL) else { return nil }
    return .differentServer(machineHost: link.host, accountHost: CloudDeviceApprovalLink.displayHost(of: serverURL))
  }

  /// Approves a machine's `codevisor auth login` request on this account.
  public func approveDevice(_ link: CloudDeviceApprovalLink) async throws {
    let token = try deviceApprovalToken(for: link)
    try await client.approveDevice(userCode: link.userCode, token: token)
  }

  /// Rejects a machine's `codevisor auth login` request.
  public func denyDevice(_ link: CloudDeviceApprovalLink) async throws {
    let token = try deviceApprovalToken(for: link)
    try await client.denyDevice(userCode: link.userCode, token: token)
  }

  private func deviceApprovalToken(for link: CloudDeviceApprovalLink) throws -> String {
    if let mismatch = deviceApprovalServerMismatch(for: link) { throw mismatch }
    guard state.isSignedIn, let token = storedToken else { throw CloudDeviceApprovalError.signInRequired }
    return token
  }
}
