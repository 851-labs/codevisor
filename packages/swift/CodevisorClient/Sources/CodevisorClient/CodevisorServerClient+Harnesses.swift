import ACPKit
import CodevisorProtocol
import Foundation

private struct UpdateHarnessBody: Encodable {
    var enabled: Bool
}

private struct HarnessAccountBody: Encodable { var label: String? }

private struct HarnessLoginBody: Encodable {
    var methodId: String?
    var apiKey: String?
}

private struct PiAuthStartBody: Encodable { var method: String }

private struct PiAuthAnswerBody: Encodable { var value: String }

private struct OpenCodeAuthStartBody: Encodable {
    var methodId: String
    var inputs: [String: String]?
    var apiKey: String?
}

private struct OpenCodeAuthAnswerBody: Encodable { var code: String }

extension CodevisorServerClient {
    public func listHarnesses() async throws -> [ServerHarness] {
        try await get("/v1/harnesses")
    }

    public func listHarnessesWithLifecycle() async throws -> [ServerHarness] {
        try await get("/v1/harnesses?include=lifecycle")
    }

    public func rescanHarnesses() async throws -> [ServerHarness] {
        do {
            return try await send(
                "/v1/harnesses/rescan",
                method: "POST",
                body: Optional<EmptyBody>.none
            )
        } catch CodevisorServerClientError.httpStatus(404, _) {
            // Older servers predate the rescan endpoint; a plain list is the
            // best they can do (their PATH stays frozen until they update).
            return try await listHarnesses()
        }
    }

    public func listAgentSessions(harnessId: String) async throws -> [SessionInfo] {
        let encoded = harnessId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? harnessId
        return try await get("/v1/harnesses/\(encoded)/agent-sessions")
    }

    public func setHarnessEnabled(id: String, enabled: Bool) async throws -> ServerHarness {
        try await send(
            "/v1/harnesses/\(id)",
            method: "PATCH",
            body: UpdateHarnessBody(enabled: enabled)
        )
    }

    public func listCustomHarnesses() async throws -> [ServerCustomHarnessSpec] {
        let envelope: ServerCustomHarnessListEnvelope = try await get("/v1/harnesses/custom")
        return envelope.harnesses
    }

    public func replaceCustomHarnesses(_ specs: [ServerCustomHarnessSpec]) async throws -> [ServerHarness] {
        try await send(
            "/v1/harnesses/custom",
            method: "PUT",
            body: ServerCustomHarnessListEnvelope(harnesses: specs)
        )
    }

    public func testCustomHarness(_ spec: ServerCustomHarnessSpec) async throws -> ServerCustomHarnessTestResult {
        try await send("/v1/harnesses/custom/test", method: "POST", body: spec)
    }

    public func installHarness(id: String, methodId: String?) async throws -> ServerHarnessOperationStarted {
        struct InstallBody: Encodable { var methodId: String? }
        let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        return try await send(
            "/v1/harnesses/\(encoded)/install",
            method: "POST",
            body: InstallBody(methodId: methodId)
        )
    }

    public func updateHarness(id: String) async throws -> ServerHarnessOperationStarted {
        let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        return try await send(
            "/v1/harnesses/\(encoded)/update",
            method: "POST",
            body: Optional<EmptyBody>.none
        )
    }

    public func bundledAppInfo(harnessId: String) async throws -> ServerHarnessBundledApp? {
        let encoded = harnessId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? harnessId
        do {
            return try await get("/v1/harnesses/\(encoded)/bundled-app")
        } catch CodevisorServerClientError.httpStatus(404, _) {
            return nil
        }
    }

    public func updateBundledApp(harnessId: String) async throws {
        let encoded = harnessId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? harnessId
        let _: ServerHarnessOperationStarted = try await send(
            "/v1/harnesses/\(encoded)/bundled-app/update",
            method: "POST",
            body: Optional<EmptyBody>.none
        )
    }

    public func applyPendingHarnessUpdate(id: String) async throws {
        let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        let _: ServerHarnessOperationStarted = try await send(
            "/v1/harnesses/\(encoded)/update/pending/apply",
            method: "POST",
            body: Optional<EmptyBody>.none
        )
    }

    public func cancelPendingHarnessUpdate(id: String) async throws {
        let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        try await sendNoResponse("/v1/harnesses/\(encoded)/update/pending", method: "DELETE")
    }

    public func checkHarnessUpdates() async throws -> [ServerHarness] {
        do {
            return try await send(
                "/v1/harnesses/check-updates",
                method: "POST",
                body: Optional<EmptyBody>.none
            )
        } catch CodevisorServerClientError.httpStatus(404, _), CodevisorServerClientError.httpStatus(501, _) {
            // Older servers predate update checks; the plain list is the best
            // they can do.
            return try await listHarnesses()
        }
    }

    public func refreshHarnessAuth() async throws -> [ServerHarness] {
        try await send("/v1/harnesses/auth/refresh", method: "POST", body: Optional<EmptyBody>.none)
    }

    public func refreshHarnessAuth(harnessId: String) async throws -> ServerHarness {
        let encoded = harnessId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? harnessId
        let refreshed: [ServerHarness] = try await send(
            "/v1/harnesses/auth/refresh?harnessId=\(encoded)",
            method: "POST",
            body: Optional<EmptyBody>.none
        )
        guard let harness = refreshed.first(where: { $0.id == harnessId }) else {
            throw CodevisorServerClientError.invalidResponse
        }
        return harness
    }

    public func listHarnessAccounts(harnessId: String) async throws -> [ServerHarnessAccount] {
        try await get(harnessAccountsPath(harnessId))
    }

    public func createHarnessAccount(harnessId: String, label: String?) async throws -> ServerHarnessAccount {
        try await send(harnessAccountsPath(harnessId), method: "POST", body: HarnessAccountBody(label: label))
    }

    public func renameHarnessAccount(
        harnessId: String, accountId: String, label: String
    ) async throws -> ServerHarnessAccount {
        try await send(
            harnessAccountPath(harnessId, accountId), method: "PATCH", body: HarnessAccountBody(label: label))
    }

    public func removeHarnessAccount(harnessId: String, accountId: String) async throws {
        try await sendNoResponse(harnessAccountPath(harnessId, accountId), method: "DELETE")
    }

    public func activateHarnessAccount(harnessId: String, accountId: String) async throws -> [ServerHarnessAccount] {
        try await send(
            "\(harnessAccountPath(harnessId, accountId))/activate", method: "POST", body: Optional<EmptyBody>.none)
    }

    public func probeHarnessAccount(harnessId: String, accountId: String) async throws -> ServerHarnessAccount {
        try await send(
            "\(harnessAccountPath(harnessId, accountId))/auth/probe", method: "POST", body: Optional<EmptyBody>.none)
    }

    public func loginHarnessAccount(
        harnessId: String, accountId: String, methodId: String?, apiKey: String?
    ) async throws -> ServerHarnessAuthFlow {
        try await send(
            "\(harnessAccountPath(harnessId, accountId))/login", method: "POST",
            body: HarnessLoginBody(methodId: methodId, apiKey: apiKey))
    }

    public func cancelHarnessLogin(harnessId: String, accountId: String, flowId: String) async throws {
        try await sendNoResponse(
            "\(harnessAccountPath(harnessId, accountId))/login/\(pathComponent(flowId))", method: "DELETE")
    }

    public func logoutHarnessAccount(harnessId: String, accountId: String) async throws -> ServerHarnessAccount {
        try await send(
            "\(harnessAccountPath(harnessId, accountId))/logout", method: "POST", body: Optional<EmptyBody>.none)
    }

    public func listPiAuthProviders() async throws -> [ServerPiAuthProvider] {
        try await get("/v1/harnesses/pi/providers")
    }

    public func startPiAuth(providerId: String, method: String) async throws -> ServerPiAuthFlow {
        try await send(
            "/v1/harnesses/pi/providers/\(pathComponent(providerId))/login",
            method: "POST",
            body: PiAuthStartBody(method: method)
        )
    }

    public func piAuthFlow(id: String) async throws -> ServerPiAuthFlow {
        try await get("/v1/harnesses/pi/auth-flows/\(pathComponent(id))")
    }

    public func answerPiAuthFlow(id: String, value: String) async throws -> ServerPiAuthFlow {
        try await send(
            "/v1/harnesses/pi/auth-flows/\(pathComponent(id))/answer",
            method: "POST",
            body: PiAuthAnswerBody(value: value)
        )
    }

    public func cancelPiAuthFlow(id: String) async throws {
        try await sendNoResponse("/v1/harnesses/pi/auth-flows/\(pathComponent(id))", method: "DELETE")
    }

    public func removePiAuthProvider(id: String) async throws {
        try await sendNoResponse("/v1/harnesses/pi/providers/\(pathComponent(id))", method: "DELETE")
    }

    public func listOpenCodeAuthProviders(accountId: String) async throws -> [ServerOpenCodeAuthProvider] {
        try await get(openCodeProvidersPath(accountId))
    }

    public func startOpenCodeAuth(
        accountId: String, providerId: String, methodId: String, inputs: [String: String]?, apiKey: String?
    ) async throws -> ServerOpenCodeAuthFlow {
        try await send(
            "\(openCodeProvidersPath(accountId))/\(pathComponent(providerId))/login",
            method: "POST",
            body: OpenCodeAuthStartBody(methodId: methodId, inputs: inputs, apiKey: apiKey)
        )
    }

    public func openCodeAuthFlow(id: String) async throws -> ServerOpenCodeAuthFlow {
        try await get("/v1/harnesses/opencode/auth-flows/\(pathComponent(id))")
    }

    public func answerOpenCodeAuthFlow(id: String, code: String) async throws -> ServerOpenCodeAuthFlow {
        try await send(
            "/v1/harnesses/opencode/auth-flows/\(pathComponent(id))/answer",
            method: "POST",
            body: OpenCodeAuthAnswerBody(code: code)
        )
    }

    public func cancelOpenCodeAuthFlow(id: String) async throws {
        try await sendNoResponse("/v1/harnesses/opencode/auth-flows/\(pathComponent(id))", method: "DELETE")
    }

    public func removeOpenCodeAuthProvider(accountId: String, providerId: String) async throws {
        try await sendNoResponse(
            "\(openCodeProvidersPath(accountId))/\(pathComponent(providerId))",
            method: "DELETE"
        )
    }
}
