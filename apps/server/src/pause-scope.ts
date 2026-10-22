export type PauseScope =
  | { readonly kind: "all" }
  | { readonly kind: "harnesses"; readonly harnessIds: ReadonlyArray<string> }

export const allChats: PauseScope = { kind: "all" }

export const harnessChats = (harnessIds: ReadonlyArray<string>): PauseScope => ({
  kind: "harnesses",
  harnessIds: [...new Set(harnessIds)].toSorted()
})

export const widenScope = (current: PauseScope, requested: PauseScope): PauseScope => {
  if (current.kind === "all" || requested.kind === "all") return allChats

  return harnessChats([...current.harnessIds, ...requested.harnessIds])
}

export const sameScope = (left: PauseScope, right: PauseScope): boolean =>
  scopeKey(left) === scopeKey(right)

export const scopeIncludes = (scope: PauseScope, harnessId: string | undefined): boolean => {
  if (scope.kind === "all") return true

  return harnessId !== undefined && scope.harnessIds.includes(harnessId)
}

const scopeKey = (scope: PauseScope): string =>
  scope.kind === "all" ? "*" : scope.harnessIds.join("\n")
