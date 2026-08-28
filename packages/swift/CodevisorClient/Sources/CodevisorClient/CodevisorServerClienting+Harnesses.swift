public extension CodevisorServerClienting {
    /// Persists the user's preference. The returned harness's `enabled` value
    /// can remain false while authentication or readiness gates are unmet;
    /// use `isDesiredEnabled` to render the preference.
    func setHarnessDesiredEnabled(id: String, enabled: Bool) async throws -> ServerHarness {
        try await setHarnessEnabled(id: id, enabled: enabled)
    }
}
