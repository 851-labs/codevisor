import Foundation
import ACPKit

/// How a known harness is launched once its CLI is detected.
public enum HarnessLaunch: Sendable, Equatable {
    /// Run an ACP adapter via `npx -y <package> <args…>`.
    case npx(package: String, args: [String] = [])
    /// Run an ACP adapter binary already on `PATH`.
    case binaryOnPath(name: String, args: [String] = [])
}

/// A known coding harness: a display identity, the CLI(s) whose presence means
/// it is installed, and how to launch its ACP adapter.
public struct HarnessDefinition: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let symbolName: String
    /// The harness is considered installed if any of these are on `PATH`.
    public let detectBinaries: [String]
    public let launch: HarnessLaunch

    public init(id: String, name: String, symbolName: String, detectBinaries: [String], launch: HarnessLaunch) {
        self.id = id
        self.name = name
        self.symbolName = symbolName
        self.detectBinaries = detectBinaries
        self.launch = launch
    }
}

/// The catalog of harnesses HerdMan knows how to detect and launch, mirroring the
/// official ACP agent registry (https://cdn.agentclientprotocol.com/registry).
/// Each entry records the CLI(s) whose presence means the harness is installed
/// and how to launch its ACP adapter (an `npx` package wrapping the vendor CLI,
/// or an ACP-capable binary already on `PATH`).
public enum HarnessCatalog {
    public static let known: [HarnessDefinition] = [
        HarnessDefinition(
            id: "claude-code",
            name: "Claude Code",
            symbolName: "sparkle",
            detectBinaries: ["claude"],
            launch: .npx(package: "@agentclientprotocol/claude-agent-acp@0.53.0")
        ),
        HarnessDefinition(
            id: "codex",
            name: "Codex",
            symbolName: "chevron.left.forwardslash.chevron.right",
            detectBinaries: ["codex"],
            launch: .npx(package: "@agentclientprotocol/codex-acp@1.0.2")
        ),
        HarnessDefinition(
            id: "gemini",
            name: "Gemini CLI",
            symbolName: "diamond",
            detectBinaries: ["gemini"],
            launch: .npx(package: "@google/gemini-cli@0.49.0", args: ["--acp"])
        ),
        HarnessDefinition(
            id: "opencode",
            name: "OpenCode",
            symbolName: "curlybraces",
            detectBinaries: ["opencode"],
            launch: .binaryOnPath(name: "opencode", args: ["acp"])
        ),
        HarnessDefinition(
            id: "goose",
            name: "goose",
            symbolName: "bird",
            detectBinaries: ["goose"],
            launch: .binaryOnPath(name: "goose", args: ["acp"])
        ),
        HarnessDefinition(
            id: "cursor",
            name: "Cursor",
            symbolName: "cursorarrow.rays",
            detectBinaries: ["cursor-agent"],
            launch: .binaryOnPath(name: "cursor-agent", args: ["acp"])
        ),
        HarnessDefinition(
            id: "amp",
            name: "Amp",
            symbolName: "bolt",
            detectBinaries: ["amp-acp"],
            launch: .binaryOnPath(name: "amp-acp")
        ),
        HarnessDefinition(
            id: "auggie",
            name: "Auggie CLI",
            symbolName: "a.square",
            detectBinaries: ["auggie"],
            launch: .npx(package: "@augmentcode/auggie@0.31.0", args: ["--acp"])
        ),
        HarnessDefinition(
            id: "cline",
            name: "Cline",
            symbolName: "terminal",
            detectBinaries: ["cline"],
            launch: .npx(package: "cline@3.0.34", args: ["--acp"])
        ),
        HarnessDefinition(
            id: "github-copilot-cli",
            name: "GitHub Copilot",
            symbolName: "ellipsis.curlybraces",
            detectBinaries: ["copilot"],
            launch: .npx(package: "@github/copilot@1.0.65", args: ["--acp"])
        ),
        HarnessDefinition(
            id: "qwen-code",
            name: "Qwen Code",
            symbolName: "q.square",
            detectBinaries: ["qwen"],
            launch: .npx(package: "@qwen-code/qwen-code@0.19.3", args: ["--acp", "--experimental-skills"])
        ),
        HarnessDefinition(
            id: "kimi",
            name: "Kimi CLI",
            symbolName: "k.square",
            detectBinaries: ["kimi"],
            launch: .binaryOnPath(name: "kimi", args: ["acp"])
        ),
        HarnessDefinition(
            id: "factory-droid",
            name: "Factory Droid",
            symbolName: "wrench.and.screwdriver",
            detectBinaries: ["droid"],
            launch: .npx(package: "droid@0.159.1", args: ["exec", "--output-format", "acp-daemon"])
        ),
        HarnessDefinition(
            id: "devin",
            name: "Devin",
            symbolName: "brain",
            detectBinaries: ["devin"],
            launch: .binaryOnPath(name: "devin", args: ["acp"])
        ),
        HarnessDefinition(
            id: "grok-build",
            name: "Grok Build",
            symbolName: "x.square",
            detectBinaries: ["grok"],
            launch: .npx(package: "@xai-official/grok@0.2.76", args: ["agent", "stdio"])
        ),
        HarnessDefinition(
            id: "kilo",
            name: "Kilo",
            symbolName: "shippingbox",
            detectBinaries: ["kilo"],
            launch: .npx(package: "@kilocode/cli@7.3.54", args: ["acp"])
        )
    ]
}
