import { join } from "node:path"

/// Environment against which harness-catalog `~/`-relative paths resolve.
export interface NativePathEnvironment {
  readonly home: string
  readonly env?: Readonly<Record<string, string | undefined>>
}

/// Resolve a catalog `~/`-relative skills path against a home directory,
/// honoring the env overrides harnesses themselves respect: CODEX_HOME
/// relocates `~/.codex/...` and XDG_CONFIG_HOME relocates `~/.config/...`.
///
/// Deliberately duplicated from the MCP native-config plumbing (18 pure
/// lines) so the skills package stays independent of it — keep the two in
/// sync if harness path-override semantics ever change.
export const resolveNativeConfigPath = (
  specPath: string,
  environment: NativePathEnvironment
): string => {
  const env = environment.env ?? {}
  const codexHome = env["CODEX_HOME"]
  if (codexHome !== undefined && codexHome !== "" && specPath.startsWith("~/.codex/")) {
    return join(codexHome, specPath.slice("~/.codex/".length))
  }
  const xdgConfigHome = env["XDG_CONFIG_HOME"]
  if (xdgConfigHome !== undefined && xdgConfigHome !== "" && specPath.startsWith("~/.config/")) {
    return join(xdgConfigHome, specPath.slice("~/.config/".length))
  }
  if (specPath.startsWith("~/")) {
    return join(environment.home, specPath.slice(2))
  }
  return specPath
}
