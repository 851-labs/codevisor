import { FLEET_MIRROR_PATH, type FleetMirrorAction } from "@codevisor/api"

import type { MachineLink } from "./machine-link.js"
import type { PreparedMirror } from "./mirror-store.js"
import type { MirrorTransport } from "./workspace-sync-runner.js"

export interface MirrorTransportSelf {
  readonly id: string
  readonly name: () => string
}

export const fleetMirrorTransport = (
  link: Pick<MachineLink, "invoke">,
  self: MirrorTransportSelf
): MirrorTransport => {
  const send = (machineId: string, action: FleetMirrorAction) =>
    link.invoke(machineId, FLEET_MIRROR_PATH, action, {
      machineId: self.id,
      machineName: self.name()
    })

  return {
    prepare: async (machineId, mirrorId, name) =>
      preparedMirror(await send(machineId, { action: "prepare", mirrorId, name })),
    write: async (machineId, mirrorId, offset, data) => {
      await send(machineId, { action: "write", mirrorId, offset, data: data.toString("base64") })
    },
    apply: async (machineId, mirrorId, commit, head) =>
      preparedMirror(
        await send(machineId, {
          action: "apply",
          mirrorId,
          commit,
          ...(head === undefined ? {} : { head })
        })
      ),
    remove: async (machineId, mirrorId) => {
      await send(machineId, { action: "remove", mirrorId })
    }
  }
}

const preparedMirror = (value: unknown): PreparedMirror => {
  if (typeof value !== "object" || value === null || !("path" in value)) {
    throw new Error("The other machine answered without a mirror path")
  }
  const head = "head" in value && typeof value.head === "string" ? value.head : undefined
  const sourceHead =
    "sourceHead" in value && typeof value.sourceHead === "string" ? value.sourceHead : undefined
  if (typeof value.path !== "string") throw new Error("The other machine sent a bad mirror path")
  return {
    path: value.path,
    ...(head === undefined ? {} : { head }),
    ...(sourceHead === undefined ? {} : { sourceHead })
  }
}
