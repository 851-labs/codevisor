import os

/// Package-internal logging handle. CodevisorTheming must not depend on
/// CodevisorCore, so it carries its own `Logger` under the app's shared
/// subsystem. Interpolated error strings use `privacy: .public` so
/// release-build diagnostics stay readable; never log file contents.
let themingLog = Logger(subsystem: "com.851labs.codevisor", category: "theming")
