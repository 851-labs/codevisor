import CodevisorClient
import Foundation

/// A parsed `codevisor://cloud-auth?ott=…` deeplink — the browser handoff's
/// way back into the app after a cloud sign-in. The one-time token is
/// exchanged for a session immediately; it is useless after that (and expires
/// within minutes regardless), so no confirmation gate is needed.
public struct CloudAuthDeeplink: Equatable, Sendable {
    public var ott: String

    public init(ott: String) {
        self.ott = ott
    }

    /// Accepts `codevisor://` and `codevisor-dev://` so a development build
    /// can handle a link generated for production installs.
    public static func parse(_ url: URL) -> CloudAuthDeeplink? {
        guard let scheme = url.scheme?.lowercased(),
            scheme == "codevisor" || scheme == "codevisor-dev",
            url.host()?.lowercased() == "cloud-auth",
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let ott = components.queryItems?
                .first(where: { $0.name == "ott" })?
                .value?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !ott.isEmpty
        else { return nil }
        return CloudAuthDeeplink(ott: ott)
    }
}
