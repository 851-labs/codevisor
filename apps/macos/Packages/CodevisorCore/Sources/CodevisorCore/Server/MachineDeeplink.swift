import Foundation

/// A parsed `codevisor://add-machine` deeplink, as printed by `codevisor
/// setup` on a remote machine. Strict about what pairing needs (host + token),
/// lenient about the rest. The handler must always confirm with the user
/// before adding — the token grants full access to run agents on the machine.
public struct MachineDeeplink: Equatable, Sendable {
    public var host: String
    public var port: Int?
    public var token: String
    public var name: String?

    public init(host: String, port: Int? = nil, token: String, name: String? = nil) {
        self.host = host
        self.port = port
        self.token = token
        self.name = name
    }

    /// The value handed to `MachineController.addRemote`, which defaults the
    /// port when absent.
    public var hostWithPort: String {
        port.map { "\(host):\($0)" } ?? host
    }

    public var displayName: String {
        name ?? host
    }

    /// Accepts `codevisor://` and `codevisor-dev://` so a development build
    /// can handle a link generated for production installs.
    public static func parse(_ url: URL) -> MachineDeeplink? {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "codevisor" || scheme == "codevisor-dev",
              url.host()?.lowercased() == "add-machine",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }

        var values: [String: String] = [:]
        for item in components.queryItems ?? [] {
            if let value = item.value?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                values[item.name] = value
            }
        }
        guard let host = values["host"], let token = values["token"] else { return nil }
        let port = values["port"].flatMap(Int.init).flatMap { (1...65_535).contains($0) ? $0 : nil }
        return MachineDeeplink(host: host, port: port, token: token, name: values["name"])
    }
}
