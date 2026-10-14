import type { HarnessDefinition } from "./types.js"

export function executableHarness(
  id: string,
  name: string,
  symbolName: string,
  detectBinaries: ReadonlyArray<string>,
  command: string,
  args: ReadonlyArray<string> = [],
  extra: Partial<
    Pick<
      HarnessDefinition,
      | "installMethods"
      | "update"
      | "installHint"
      | "fallbackPaths"
      | "nativeMcp"
      | "skills"
      | "provider"
      | "requiredBinaries"
    >
  > = {}
): HarnessDefinition {
  return {
    detectBinaries,
    id,
    launch: { args, command, kind: "executable" },
    name,
    provider: "acp",
    symbolName,
    ...extra
  }
}
