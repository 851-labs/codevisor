import Foundation
import Testing

@testable import CodevisorClient

@Suite("Plugin registry browsing logic")
struct PluginRegistryBrowsingTests {
    private let gitDiff = ServerPluginRegistryEntry(
        id: "acme.git-diff",
        name: "Git Diff",
        version: "0.1.0",
        description: "Live git diff viewer",
        panes: [ServerPluginPaneDescriptor(type: "diff", title: "Git Diff", path: "/panes/diff/")],
        tools: [
            ServerPluginToolDescriptor(
                name: "diff_summary", description: "Summarize the diff", path: "/tools/summary"
            )
        ],
        repo: "acme/git-diff",
        stars: 12,
        pushedAt: "2026-08-17T00:00:00Z"
    )

    private let notes = ServerPluginRegistryEntry(
        id: "beta.notes",
        name: "Notes",
        version: "1.0.0",
        panes: [],
        tools: [
            ServerPluginToolDescriptor(name: "notes_add", description: "Add a note", path: "/add"),
            ServerPluginToolDescriptor(name: "notes_list", description: "List notes", path: "/list"),
        ],
        repo: "beta/notes-plugin",
        stars: 3,
        pushedAt: "2026-08-16T00:00:00Z"
    )

    @Test("Filtering matches case-insensitively across id, name, description, and repo")
    func filtering() {
        let entries = [gitDiff, notes]
        #expect(
            PluginRegistryBrowsing.filter(entries, query: "").map(\.id) == [
                "acme.git-diff", "beta.notes",
            ])
        #expect(
            PluginRegistryBrowsing.filter(entries, query: "  \n").map(\.id) == [
                "acme.git-diff", "beta.notes",
            ])
        #expect(PluginRegistryBrowsing.filter(entries, query: "GIT").map(\.id) == ["acme.git-diff"])
        // "viewer" only appears in the description.
        #expect(PluginRegistryBrowsing.filter(entries, query: "viewer").map(\.id) == ["acme.git-diff"])
        // "notes-plugin" only appears in the repo; the entry has no description.
        #expect(
            PluginRegistryBrowsing.filter(entries, query: "notes-PLUGIN").map(\.id) == [
                "beta.notes"
            ])
        #expect(PluginRegistryBrowsing.filter(entries, query: "zzz").isEmpty)
    }

    @Test("Capability summaries pluralize panes and tools and omit absent kinds")
    func capabilitySummaries() {
        #expect(PluginRegistryBrowsing.capabilitySummary(for: gitDiff) == "1 pane · 1 agent tool")
        #expect(PluginRegistryBrowsing.capabilitySummary(for: notes) == "2 agent tools")
        var bare = notes
        bare.tools = nil
        #expect(PluginRegistryBrowsing.capabilitySummary(for: bare).isEmpty)
        bare.tools = []
        #expect(PluginRegistryBrowsing.capabilitySummary(for: bare).isEmpty)
        var panesOnly = gitDiff
        panesOnly.tools = nil
        panesOnly.panes.append(
            ServerPluginPaneDescriptor(type: "log", title: "Log", path: "/panes/log/")
        )
        #expect(PluginRegistryBrowsing.capabilitySummary(for: panesOnly) == "2 panes")
    }

    @Test("Installed markers key off the plugin id, not the repo")
    func installedMarkers() {
        #expect(PluginRegistryBrowsing.isInstalled(gitDiff, installedIds: ["acme.git-diff"]))
        #expect(!PluginRegistryBrowsing.isInstalled(notes, installedIds: ["acme.git-diff"]))
        #expect(!PluginRegistryBrowsing.isInstalled(notes, installedIds: []))
    }
}
