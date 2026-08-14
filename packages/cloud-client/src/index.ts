/// Client-side building blocks for the cloud relay: login flows (device code
/// for machines, sessions for tooling) and the machine-side hub connection.
///
/// Everything external is injected — `fetch` for HTTP, a socket factory for
/// WebSockets — so the logic is fully unit-testable and runs identically under
/// Node/Bun (apps/server and development tooling) and other future runtimes.
export * from "./login.js"
export * from "./machine-connection.js"
export * from "./cloud-proxy.js"
