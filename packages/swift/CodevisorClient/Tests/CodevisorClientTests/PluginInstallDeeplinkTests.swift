import Foundation
import Testing

@testable import CodevisorClient

@Suite("PluginInstallDeeplink")
struct PluginInstallDeeplinkTests {
    @Test("Parses an install-plugin link with a GitHub repo")
    func parsesRepoLink() {
        let url = URL(string: "codevisor://install-plugin?repo=octocat/notes-pane")!
        #expect(PluginInstallDeeplink.parse(url) == PluginInstallDeeplink(repo: "octocat/notes-pane"))
    }

    @Test("Accepts the dev scheme and dotted repo names")
    func parsesDevScheme() {
        let url = URL(string: "codevisor-dev://install-plugin?repo=my-org/plugin.v2")!
        #expect(PluginInstallDeeplink.parse(url) == PluginInstallDeeplink(repo: "my-org/plugin.v2"))
    }

    @Test("Accepts per-instance dev schemes")
    func parsesInstanceScheme() {
        // `bun run dev` registers codevisor-dev-<instance hash> so parallel
        // dev worktrees never race for one handler.
        let url = URL(string: "codevisor-dev-ab12cd34ef://install-plugin?repo=octocat/notes")!
        #expect(PluginInstallDeeplink.parse(url) == PluginInstallDeeplink(repo: "octocat/notes"))
        // The family is codevisor-dev-*: other codevisor-ish schemes stay foreign.
        #expect(
            PluginInstallDeeplink.parse(
                URL(string: "codevisor-evil://install-plugin?repo=octocat/notes")!
            ) == nil
        )
    }

    @Test("Rejects foreign schemes, other actions, and missing repos")
    func rejectsInvalidLinks() {
        let rejected = [
            "https://install-plugin?repo=octocat/notes",
            "codevisor://add-machine?host=h&token=t",
            "codevisor://install-plugin",
            "codevisor://install-plugin?repo=",
            "codevisor://install-plugin?repo=%20",
        ]
        for raw in rejected {
            #expect(PluginInstallDeeplink.parse(URL(string: raw)!) == nil, "expected nil for \(raw)")
        }
    }

    @Test("Rejects sources that are not a bare GitHub owner/name")
    func rejectsNonRepoSources() {
        let rejected = [
            // Free-form install sources stay a manual, in-app affair: a link
            // must never point at a local path or an arbitrary git remote.
            "codevisor://install-plugin?repo=/usr/local/evil",
            "codevisor://install-plugin?repo=../../etc",
            "codevisor://install-plugin?repo=owner/name/extra",
            "codevisor://install-plugin?repo=https%3A%2F%2Fevil.example%2Frepo.git",
            "codevisor://install-plugin?repo=owner",
            "codevisor://install-plugin?repo=owner/-leading-dash",
            "codevisor://install-plugin?repo=owner/name%20space",
        ]
        for raw in rejected {
            #expect(PluginInstallDeeplink.parse(URL(string: raw)!) == nil, "expected nil for \(raw)")
        }
    }
}
