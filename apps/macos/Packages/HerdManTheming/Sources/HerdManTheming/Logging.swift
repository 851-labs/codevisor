import os

/// Package-internal logging handle. HerdManTheming must not depend on
/// HerdManCore, so it carries its own `Logger` under the app's shared
/// subsystem. Interpolated error strings use `privacy: .public` so
/// release-build diagnostics stay readable; never log file contents.
let themingLog = Logger(subsystem: "com.851labs.herdman", category: "theming")
