import Foundation
import Testing

@testable import CodevisorClient

struct LegacyDefaultsMigrationTests {
    private func scratchDefaults() -> UserDefaults {
        let suite = "codevisor.tests.legacy-defaults.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test func copiesLegacyKeysAndSetsMarker() {
        let defaults = scratchDefaults()
        LegacyDefaultsMigration.apply(
            legacy: ["SUEnableAutomaticChecks": true, "someKey": "legacy"],
            to: defaults
        )
        #expect(defaults.bool(forKey: "SUEnableAutomaticChecks") == true)
        #expect(defaults.string(forKey: "someKey") == "legacy")
        #expect(defaults.bool(forKey: LegacyDefaultsMigration.markerKey) == true)
    }

    @Test func existingKeysWin() {
        let defaults = scratchDefaults()
        defaults.set("current", forKey: "someKey")
        LegacyDefaultsMigration.apply(legacy: ["someKey": "legacy"], to: defaults)
        #expect(defaults.string(forKey: "someKey") == "current")
    }

    @Test func runsOnlyOnce() {
        let defaults = scratchDefaults()
        LegacyDefaultsMigration.apply(legacy: [:], to: defaults)
        LegacyDefaultsMigration.apply(legacy: ["late": "value"], to: defaults)
        #expect(defaults.object(forKey: "late") == nil)
    }
}
