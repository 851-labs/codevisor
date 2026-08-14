import os

/// Package-internal logging handle. ACPKit must not depend on CodevisorCore, so
/// it carries its own `Logger` under the app's shared subsystem. Interpolated
/// error strings use `privacy: .public` so release-build diagnostics stay
/// readable; never log message bodies or file contents.
let acpLog = Logger(subsystem: "com.851labs.codevisor", category: "acp")
