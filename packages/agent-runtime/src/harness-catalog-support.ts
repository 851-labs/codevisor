import type { HarnessDefinition, HarnessLaunch } from "./types.js"

type ExecutableLaunch = Extract<HarnessLaunch, { readonly kind: "executable" }>

type HarnessExtras = Partial<
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
> &
  Pick<ExecutableLaunch, "env" | "files" | "trustFlag">

export function executableHarness(
  id: string,
  name: string,
  symbolName: string,
  detectBinaries: ReadonlyArray<string>,
  command: string,
  args: ReadonlyArray<string> = [],
  extra: HarnessExtras = {}
): HarnessDefinition {
  const { env, files, trustFlag, ...definition } = extra
  return {
    detectBinaries,
    id,
    launch: {
      args,
      command,
      kind: "executable",
      ...(env === undefined ? {} : { env }),
      ...(files === undefined ? {} : { files }),
      ...(trustFlag === undefined ? {} : { trustFlag })
    },
    name,
    provider: "acp",
    symbolName,
    ...definition
  }
}
