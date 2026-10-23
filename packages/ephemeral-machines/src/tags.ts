import type { EphemeralTags, ListedMachine } from "./provider.js"

export const OWNER_TAG = "codevisor-owner"
export const MACHINE_TAG = "codevisor-machine"

export const tagsToRecord = (tags: EphemeralTags): Record<string, string> => ({
  [OWNER_TAG]: tags.owner,
  [MACHINE_TAG]: tags.machine
})

export const ownerFilter = (owner: string): Record<string, string> => ({ [OWNER_TAG]: owner })

export const listedMachine = (
  providerMachineId: string,
  record: Readonly<Record<string, string>>
): ReadonlyArray<ListedMachine> => {
  const owner = record[OWNER_TAG]
  const machine = record[MACHINE_TAG]
  if (owner === undefined || machine === undefined) return []

  return [{ providerMachineId, tags: { owner, machine } }]
}
