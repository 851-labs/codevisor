import Foundation
import ACPKit

/// Discovers ACP agents that can run on this machine by combining registry
/// manifests with the resolved shell environment, plus a scan of `PATH` for
/// any `*-acp` executables. The logic is entirely registry/convention driven —
/// it has no per-agent special cases.
public struct AgentDiscovery: Sendable {
    private let probe: EnvironmentProbe
    private let platformKey: String

    public init(
        probe: EnvironmentProbe = EnvironmentProbe(),
        platformKey: String = AgentDiscovery.currentPlatformKey
    ) {
        self.probe = probe
        self.platformKey = platformKey
    }

    /// The registry platform key for the host (e.g. `darwin-aarch64`).
    public static var currentPlatformKey: String {
        #if arch(arm64)
        return "darwin-aarch64"
        #else
        return "darwin-x86_64"
        #endif
    }

    /// Produces the full set of discovered agents for a given registry.
    public func discover(from registry: AgentRegistry) async -> [DiscoveredAgent] {
        let path = await probe.resolvedPath()
        let environment = probe.resolvedEnvironment(path: path)

        var agents = registry.agents.map { manifest in
            resolve(manifest: manifest, path: path, environment: environment)
        }

        // Add any ACP binaries on PATH that are not already represented.
        let known = Set(agents.compactMap { $0.launchSpec?.executableURL.lastPathComponent })
        for executable in probe.executables(inPath: path, matching: { $0.hasSuffix("-acp") }) {
            let name = executable.lastPathComponent
            if known.contains(name) { continue }
            agents.append(DiscoveredAgent(
                id: name,
                name: name,
                source: .path,
                method: .executable,
                readiness: .ready,
                launchSpec: ProcessSpec(executableURL: executable, environment: environment)
            ))
        }
        return agents
    }

    /// Resolves a single manifest to a discovered agent, choosing the best
    /// available launch method.
    func resolve(manifest: AgentManifest, path: String, environment: [String: String]) -> DiscoveredAgent {
        let distribution = manifest.distribution

        // Prefer an installed native binary for this platform.
        if let binary = distribution.binary?[platformKey] {
            if probe.locate(binary.cmd, inPath: path) != nil || FileManager.default.isExecutableFile(atPath: binary.cmd) {
                let executable = probe.locate(binary.cmd, inPath: path) ?? URL(fileURLWithPath: binary.cmd)
                return agent(manifest, .binary, .ready, ProcessSpec(
                    executableURL: executable,
                    arguments: binary.args ?? [],
                    environment: environment
                ))
            }
        }

        // Then an npx package, if npx is available.
        if let npx = distribution.npx {
            if let npxURL = probe.locate("npx", inPath: path) {
                var arguments = ["-y", npx.package]
                arguments.append(contentsOf: npx.args ?? [])
                return agent(manifest, .npx, .ready, ProcessSpec(
                    executableURL: npxURL,
                    arguments: arguments,
                    environment: environment.merging(npx.env ?? [:]) { _, new in new }
                ))
            }
            return agent(manifest, .npx, .needsRunner("npx"), nil)
        }

        // Then a uvx package, if uvx is available.
        if let uvx = distribution.uvx {
            if let uvxURL = probe.locate("uvx", inPath: path) {
                var arguments = [uvx.package]
                arguments.append(contentsOf: uvx.args ?? [])
                return agent(manifest, .uvx, .ready, ProcessSpec(
                    executableURL: uvxURL,
                    arguments: arguments,
                    environment: environment.merging(uvx.env ?? [:]) { _, new in new }
                ))
            }
            return agent(manifest, .uvx, .needsRunner("uvx"), nil)
        }

        // A binary distribution exists for the platform but isn't installed yet.
        if distribution.binary?[platformKey] != nil {
            return agent(manifest, .binary, .unavailable("Binary not installed"), nil)
        }

        return agent(manifest, .executable, .unavailable("No compatible distribution"), nil)
    }

    private func agent(
        _ manifest: AgentManifest,
        _ method: LaunchMethod,
        _ readiness: AgentReadiness,
        _ spec: ProcessSpec?
    ) -> DiscoveredAgent {
        DiscoveredAgent(
            id: manifest.id,
            name: manifest.name,
            source: .registry,
            method: method,
            readiness: readiness,
            launchSpec: spec
        )
    }
}
