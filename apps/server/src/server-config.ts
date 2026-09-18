import type { CodevisorServerConfig } from "./server-context-types.js"

/// A complete server config from partial overrides: the defaults every test
/// and embedded run starts from, with `serve` supplying the real values.
export const defaultServerConfig = (
  overrides: Partial<CodevisorServerConfig> = {}
): CodevisorServerConfig => ({
  id: overrides.id ?? "local",
  name: overrides.name ?? "Local Codevisor",
  version: overrides.version ?? "0.1.0",
  bootId: overrides.bootId ?? "test-boot",
  processId: overrides.processId ?? process.pid,
  appOwned: overrides.appOwned ?? false,
  buildNumber: overrides.buildNumber,
  sourceRevision: overrides.sourceRevision,
  serviceManaged: overrides.serviceManaged ?? false,
  kind: overrides.kind ?? "local",
  host: overrides.host ?? "127.0.0.1",
  port: overrides.port ?? 49361,
  directPathEnabled: overrides.directPathEnabled ?? true,
  worktreeNameStyle: overrides.worktreeNameStyle ?? "production",
  auth: overrides.auth ?? {
    allowLocalhostWithoutAuth: true,
    requireBearerToken: false
  },
  onShutdownRequested: overrides.onShutdownRequested,
  updater: overrides.updater,
  restartSnapshotPath: overrides.restartSnapshotPath,
  restartDrainTimeoutMs: overrides.restartDrainTimeoutMs,
  sessionActivity: overrides.sessionActivity,
  screenSharing: overrides.screenSharing,
  screenSharingVNC: overrides.screenSharingVNC,
  cloudDeviceId: overrides.cloudDeviceId,
  cloud: overrides.cloud
})
