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
            "panes":[{"type":"diff","title":"Git Diff","path":"/panes/diff/","icon":"plus.forwardslash.minus"}],
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
        #expect(
            plugin.panes == [
                ServerPluginPaneDescriptor(
                    type: "diff", title: "Git Diff", path: "/panes/diff/",
                    icon: "plus.forwardslash.minus"
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
    }

    @Test("Remote discovery decodes the verbatim install and run commands")
    func discoveryDecoding() throws {
        let full = Data(
            """
            {"id":"acme.git-diff","name":"Git Diff","version":"0.1.0",
            "description":"Live git diff viewer",
            "panes":[{"type":"diff","title":"Git Diff","path":"/panes/diff/"}],
            "installCommand":"bun install","runCommand":"bun run start","alreadyInstalled":true}
            """.utf8)
        let discovery = try JSONDecoder().decode(ServerPluginRemoteDiscovery.self, from: full)
        #expect(discovery.id == "acme.git-diff")
        #expect(discovery.installCommand == "bun install")
        #expect(discovery.runCommand == "bun run start")
        #expect(discovery.alreadyInstalled)
        #expect(discovery.panes.count == 1)

        // Zero-dependency plugins have no install command or description.
        let bare = Data(
            """
            {"id":"a.b","name":"B","version":"1.0.0","panes":[],
            "runCommand":"./serve","alreadyInstalled":false}
            """.utf8)
        let minimal = try JSONDecoder().decode(ServerPluginRemoteDiscovery.self, from: bare)
        #expect(minimal.installCommand == nil)
        #expect(minimal.description == nil)
        #expect(!minimal.alreadyInstalled)
    }
}
