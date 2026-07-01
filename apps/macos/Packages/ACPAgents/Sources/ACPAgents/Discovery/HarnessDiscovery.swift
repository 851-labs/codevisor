import Foundation
import ACPKit

/// Discovers only the harnesses that are actually installed on the machine:
/// catalog harnesses whose CLI is present, plus any `*-acp` adapter binaries on
/// `PATH`. Each result carries a ready-to-run `ProcessSpec`.
public struct HarnessDiscovery: Sendable {
    private let probe: EnvironmentProbe
    private let catalog: [HarnessDefinition]

    public init(
        probe: EnvironmentProbe = EnvironmentProbe(),
        catalog: [HarnessDefinition] = HarnessCatalog.known
    ) {
        self.probe = probe
        self.catalog = catalog
    }

    /// Returns the installed harnesses, ready to launch.
    public func installed() async -> [DiscoveredAgent] {
        await discoverAll().filter { $0.readiness.isReady }
    }

    /// Returns every known harness — installed or not — so the UI can present
    /// the full catalog with detection status. Ready harnesses carry a launch
    /// spec; the rest report why they are unavailable.
    public func discoverAll() async -> [DiscoveredAgent] {
        let path = await probe.resolvedPath()
        let environment = probe.resolvedEnvironment(path: path)
        var agents = catalog.map { evaluate($0, path: path, environment: environment) }

        // Add any ACP adapter binaries found directly on PATH that aren't
        // already represented by a catalog entry's launch executable.
        let known = Set(agents.compactMap { $0.launchSpec?.executableURL.lastPathComponent })
        for executable in probe.executables(inPath: path, matching: { $0.hasSuffix("-acp") })
        where !known.contains(executable.lastPathComponent) {
            agents.append(DiscoveredAgent(
                id: executable.lastPathComponent,
                name: executable.lastPathComponent,
                source: .path,
                method: .executable,
                readiness: .ready,
                launchSpec: ProcessSpec(executableURL: executable, environment: environment)
            ))
        }
        return agents
    }

    /// Evaluates a catalog harness, returning a ready agent when its CLI and
    /// runner are available, or an unavailable agent (no launch spec) otherwise.
    func evaluate(_ harness: HarnessDefinition, path: String, environment: [String: String]) -> DiscoveredAgent {
        switch harness.launch {
        case let .npx(package, args):
            let isInstalled = harness.detectBinaries.contains { probe.locate($0, inPath: path) != nil }
            guard isInstalled else { return unavailable(harness, .npx, "Not installed") }
            guard let npx = probe.locate("npx", inPath: path) else {
                return unavailable(harness, .npx, "Requires Node (npx)")
            }
            return agent(harness, method: .npx, executable: npx, arguments: ["-y", package] + args, environment: environment)
        case let .binaryOnPath(name, args):
            guard let executable = probe.locate(name, inPath: path) else {
                return unavailable(harness, .executable, "Not installed")
            }
            return agent(harness, method: .executable, executable: executable, arguments: args, environment: environment)
        }
    }

    private func unavailable(_ harness: HarnessDefinition, _ method: LaunchMethod, _ reason: String) -> DiscoveredAgent {
        DiscoveredAgent(
            id: harness.id,
            name: harness.name,
            source: .registry,
            method: method,
            readiness: .unavailable(reason),
            launchSpec: nil,
            symbolName: harness.symbolName
        )
    }

    private func agent(
        _ harness: HarnessDefinition,
        method: LaunchMethod,
        executable: URL,
        arguments: [String],
        environment: [String: String]
    ) -> DiscoveredAgent {
        DiscoveredAgent(
            id: harness.id,
            name: harness.name,
            source: .registry,
            method: method,
            readiness: .ready,
            launchSpec: ProcessSpec(executableURL: executable, arguments: arguments, environment: environment),
            symbolName: harness.symbolName
        )
    }
}
