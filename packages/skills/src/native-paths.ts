import { join } from "node:path"

export interface NativePathEnvironment {
  readonly home: string
  readonly env?: Readonly<Record<string, string | undefined>>
}

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
