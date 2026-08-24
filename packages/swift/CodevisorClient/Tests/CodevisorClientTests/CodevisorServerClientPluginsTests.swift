import Foundation
import Testing

@testable import CodevisorClient

@Suite("Server client plugin wire types")
struct CodevisorServerClientPluginsTests {
    @Test("PluginPaneTokenBody omits absent optional context")
    func tokenBodyEncoding() throws {
        func json(_ body: CodevisorServerClient.PluginPaneTokenBody) throws -> String {
            String(decoding: try JSONEncoder().encode(body), as: UTF8.self)
        }
        let minimal = try json(
            CodevisorServerClient.PluginPaneTokenBody(
                paneType: "diff", workspaceId: nil, cwd: nil, themeMode: nil
            )
        )
        #expect(minimal.contains(#""paneType":"diff""#))
        #expect(!minimal.contains("workspaceId"))
        #expect(!minimal.contains("cwd"))
        #expect(!minimal.contains("themeMode"))

        let full = try json(
            CodevisorServerClient.PluginPaneTokenBody(
                paneType: "diff", workspaceId: "w-1", cwd: "/tmp/repo", themeMode: "dark"
            )
        )
        #expect(full.contains(#""workspaceId":"w-1""#))
        #expect(full.contains(#""cwd":"\/tmp\/repo""#) || full.contains(#""cwd":"/tmp/repo""#))
        #expect(full.contains(#""themeMode":"dark""#))
    }

    @Test("Plugin list and token responses decode the server's wire shapes")
    func responseDecoding() throws {
        let list = Data(
            """
            {"plugins":[{"id":"codevisor.git-diff","name":"Git Diff","version":"0.1.0",
            "description":"Live git diff viewer",
            "iconPath":"/assets/icon.svg",
            "panes":[{"type":"diff","title":"Git Diff","path":"/panes/diff/","iconPath":"/assets/diff.webp"}],
            "tools":[{"name":"diff_summary","description":"Summarize the diff","path":"/tools/summary"}],
            "source":"linked","path":"/Users/x/.codevisor/plugins/git-diff","state":"stopped",
            "openPaneCount":2}]}
            """.utf8)
        struct ListEnvelope: Decodable { var plugins: [ServerPluginSummary] }
        let decoded = try JSONDecoder().decode(ListEnvelope.self, from: list)
        #expect(decoded.plugins.count == 1)
        let plugin = try #require(decoded.plugins.first)
        #expect(plugin.id == "codevisor.git-diff")
        #expect(plugin.state == "stopped")
        #expect(plugin.openPaneCount == 2)
        #expect(plugin.iconPath == "/assets/icon.svg")
        #expect(plugin.tools?.first?.name == "diff_summary")
        #expect(
            plugin.panes == [
                ServerPluginPaneDescriptor(
                    type: "diff", title: "Git Diff", path: "/panes/diff/",
                    iconPath: "/assets/diff.webp"
                )
            ])

        // Optional fields (manifest description, route-enriched pane count)
        // stay optional for older servers.
        let bare = Data(
            """
            {"id":"a.b","name":"B","version":"1.0.0","panes":[],"source":"managed",
            "path":"/p","state":"running"}
            """.utf8)
        let bareSummary = try JSONDecoder().decode(ServerPluginSummary.self, from: bare)
        #expect(bareSummary.description == nil)
        #expect(bareSummary.tools == nil)
        #expect(bareSummary.openPaneCount == nil)

        let token = Data(
            """
            {"token":"abc","path":"/v1/plugins/codevisor.git-diff/app/panes/diff/?paneId=p&codevisorPaneToken=abc",
            "url":"http://127.0.0.1:49871/v1/plugins/codevisor.git-diff/app/panes/diff/?paneId=p&codevisorPaneToken=abc",
            "expiresAt":"2026-08-18T00:00:00.000Z"}
            """.utf8)
        let tokenResponse = try JSONDecoder().decode(ServerPluginPaneTokenResponse.self, from: token)
        #expect(tokenResponse.token == "abc")
        #expect(tokenResponse.path.hasPrefix("/v1/plugins/codevisor.git-diff/app/panes/diff/"))
        #expect(tokenResponse.url == "http://127.0.0.1:49871\(tokenResponse.path)")

        // The absolute URL is route-layer enrichment; older servers omit it.
        let bareToken = Data(
            """
            {"token":"abc","path":"/v1/plugins/a.b/app/panes/main/?codevisorPaneToken=abc",
            "expiresAt":"2026-08-18T00:00:00.000Z"}
            """.utf8)
        let bareTokenResponse = try JSONDecoder().decode(
            ServerPluginPaneTokenResponse.self, from: bareToken)
        #expect(bareTokenResponse.url == nil)
    }

    @Test("Registry indexes decode entries and skip author-facing diagnostics")
    func registryDecoding() throws {
        let wire = Data(
            """
            {"generatedAt":"2026-08-18T00:00:00.000Z",
            "entries":[{"id":"acme.git-diff","name":"Git Diff","version":"0.1.0",
            "description":"Live git diff viewer",
            "panes":[{"type":"diff","title":"Git Diff","path":"/panes/diff/"}],
            "tools":[{"name":"diff_summary","description":"Summarize the diff","path":"/tools/summary"}],
            "repo":"acme/git-diff","stars":12,"pushedAt":"2026-08-17T00:00:00Z"},
            {"id":"beta.notes","name":"Notes","version":"1.0.0","panes":[],
            "repo":"beta/notes","stars":0,"pushedAt":"2026-08-16T00:00:00Z"}],
            "rejected":[{"repo":"x/y","reason":"codevisor-plugin.json not found"}]}
            """.utf8)
        let index = try JSONDecoder().decode(ServerPluginRegistryIndex.self, from: wire)
        #expect(index.generatedAt == "2026-08-18T00:00:00.000Z")
        #expect(index.entries.count == 2)
        let entry = try #require(index.entries.first)
        #expect(entry.id == "acme.git-diff")
        #expect(entry.repo == "acme/git-diff")
        #expect(entry.stars == 12)
        #expect(entry.tools?.first?.name == "diff_summary")
        // Description/tools stay optional, exactly like installed summaries;
        // `verified` is curation groundwork the indexer never sets yet.
        let bare = try #require(index.entries.last)
        #expect(bare.description == nil)
        #expect(bare.tools == nil)
        #expect(bare.verified == nil)

        // Before the indexer's first poll, the cloud serves an honest empty
        // index whose generatedAt is null.
        let empty = Data(#"{"generatedAt":null,"entries":[],"rejected":[]}"#.utf8)
        let emptyIndex = try JSONDecoder().decode(ServerPluginRegistryIndex.self, from: empty)
        #expect(emptyIndex.generatedAt == nil)
        #expect(emptyIndex.entries.isEmpty)
    }

    @Test("Install request bodies carry the raw source and path strings")
    func installBodyEncoding() throws {
        let source = String(
            decoding: try JSONEncoder().encode(
                CodevisorServerClient.PluginSourceBody(source: "acme/git-diff#v1")
            ),
            as: UTF8.self
        )
        #expect(source == #"{"source":"acme\/git-diff#v1"}"# || source == #"{"source":"acme/git-diff#v1"}"#)
        let link = String(
            decoding: try JSONEncoder().encode(
                CodevisorServerClient.PluginLinkBody(path: "/Users/x/dev/plugin")
            ),
            as: UTF8.self
        )
        #expect(link.contains("path"))
        #expect(link.contains("plugin"))

        let apply = String(
            decoding: try JSONEncoder().encode(
                CodevisorServerClient.PluginUpdateApplyBody(planId: "plan-1")
            ),
            as: UTF8.self
        )
        #expect(apply == #"{"planId":"plan-1"}"#)
    }

    @Test("Update status and prepared review plans decode exactly")
    func updateDecoding() throws {
        let statuses = Data(
            """
            {"updates":[
            {"pluginId":"acme.git-diff","installedVersion":"1.0.0","state":"available",
            "checkedAt":"2026-08-23T00:00:00.000Z","registryVersion":"2.0.0"},
            {"pluginId":"local.dev","installedVersion":"0.1.0","state":"pinned",
            "checkedAt":"2026-08-23T00:00:00.000Z","reason":"Linked plugins are pinned"}]}
            """.utf8)
        struct UpdatesEnvelope: Decodable { var updates: [ServerPluginUpdateStatus] }
        let decodedStatuses = try JSONDecoder().decode(UpdatesEnvelope.self, from: statuses)
        #expect(decodedStatuses.updates.map(\.state) == [.available, .pinned])
        #expect(decodedStatuses.updates.first?.registryVersion == "2.0.0")
        #expect(decodedStatuses.updates.last?.reason == "Linked plugins are pinned")

        let planData = Data(
            """
            {"planId":"plan-1","pluginId":"acme.git-diff","name":"Git Diff",
            "resolvedCommit":"0123456789012345678901234567890123456789",
            "expiresAt":"2026-08-23T00:15:00.000Z",
            "current":{"version":"1.0.0","setupCommands":[],"runCommand":"node server.js",
            "panes":[{"type":"diff","title":"Diff","path":"/diff/"}]},
            "candidate":{"version":"2.0.0","setupCommands":["npm ci"],
            "runCommand":"node server.js --port $PORT","panes":[],
            "tools":[{"name":"diff_summary","description":"Summarize","path":"/tools/summary"}],
            "requirements":{"executables":[{"name":"node","installHint":"Install Node.js",
            "helpUrl":"https://nodejs.org"}]}},
            "paneChanges":{"added":[],"removed":["diff"],"changed":[]},
            "toolChanges":{"added":["diff_summary"],"removed":[],"changed":[]}}
            """.utf8)
        let plan = try JSONDecoder().decode(ServerPluginUpdatePlan.self, from: planData)
        #expect(plan.id == "plan-1")
        #expect(plan.current.version == "1.0.0")
        #expect(plan.candidate.setupCommands == ["npm ci"])
        #expect(plan.candidate.requirements?.executables?.first?.name == "node")
        #expect(plan.paneChanges.removed == ["diff"])
        #expect(plan.toolChanges.added == ["diff_summary"])
    }

    @Test("Remote discovery decodes the verbatim install and run commands")
    func discoveryDecoding() throws {
        let full = Data(
            """
            {"id":"acme.git-diff","name":"Git Diff","version":"0.1.0",
            "description":"Live git diff viewer",
            "panes":[{"type":"diff","title":"Git Diff","path":"/panes/diff/"}],
            "tools":[{"name":"diff_summary","description":"Summarize the diff",
            "path":"/tools/summary","inputSchema":{"type":"object"}}],
            "installCommand":"bun install","runCommand":"bun run start","alreadyInstalled":true}
            """.utf8)
        let discovery = try JSONDecoder().decode(ServerPluginRemoteDiscovery.self, from: full)
        #expect(discovery.id == "acme.git-diff")
        #expect(discovery.installCommand == "bun install")
        #expect(discovery.runCommand == "bun run start")
        #expect(discovery.alreadyInstalled)
        #expect(discovery.panes.count == 1)
        // Declared agent tools decode (the opaque inputSchema is skipped).
        #expect(
            discovery.tools == [
                ServerPluginToolDescriptor(
                    name: "diff_summary", description: "Summarize the diff",
                    path: "/tools/summary"
                )
            ])

        // Zero-dependency plugins have no install command, description, or
        // tools — all stay optional for older servers too.
        let bare = Data(
            """
            {"id":"a.b","name":"B","version":"1.0.0","panes":[],
            "runCommand":"./serve","alreadyInstalled":false}
            """.utf8)
        let minimal = try JSONDecoder().decode(ServerPluginRemoteDiscovery.self, from: bare)
        #expect(minimal.installCommand == nil)
        #expect(minimal.description == nil)
        #expect(minimal.tools == nil)
        #expect(!minimal.alreadyInstalled)
    }
}
