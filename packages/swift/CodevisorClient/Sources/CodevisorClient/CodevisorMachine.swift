import Foundation

public struct CodevisorMachine: Identifiable, Sendable, Codable, Equatable {
    public var id: String
    public var name: String
    public var baseURL: URL
    public var kind: String
    /// Bearer token for this machine's server. Nil for the local machine —
    /// same-machine connections are exempt from the server's token auth.
    public var token: String?
    public init(
        id: String,
        name: String,
        baseURL: URL,
        kind: String,
        token: String? = nil
    ) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.kind = kind
        self.token = token
    }

    public var isLocal: Bool { id == Self.local.id }

    /// True for machines reached through the Codevisor Cloud relay (their ids
    /// are `cloud:<deviceId>`; they are synthesized from cloud presence, not
    /// stored in the registry).
    public var isCloud: Bool { id.hasPrefix(Self.cloudIdPrefix) }

    public var serverConfig: CodevisorServerConfig {
        CodevisorServerConfig(baseURL: baseURL, bearerToken: token)
    }

    public static let local = CodevisorMachine(
        id: "local",
        name: "Local",
        baseURL: URL(string: "http://127.0.0.1:\(CodevisorServerConfig.localPort)")!,
        kind: "local"
    )

    public static let cloudIdPrefix = "cloud:"
    /// Cloud machines have no direct address; requests tunnel through the
    /// relay, so their baseURL is a recognizable placeholder.
    public static let cloudPlaceholderBaseURL = URL(string: "https://cloud-relay.invalid")!

    /// The cloud device id for a `cloud:` machine id, nil otherwise.
    public static func cloudDeviceId(forMachineId id: String) -> String? {
        guard id.hasPrefix(cloudIdPrefix) else { return nil }
        return String(id.dropFirst(cloudIdPrefix.count))
    }
}
