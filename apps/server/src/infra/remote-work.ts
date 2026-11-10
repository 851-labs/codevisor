import { join } from "node:path"

import { makeExecTasks, type ExecTasks } from "./exec-tasks.js"
import { fleetMirrorTransport, type MirrorTransportSelf } from "./fleet-mirror-transport.js"
import type { MachineLink } from "./machine-link.js"
import { makeMirrorStore, type MirrorStore } from "./mirror-store.js"
import { makeOrphanSweep, type OrphanSweep } from "./orphan-sweep.js"
import { makeRemoteExecTasks, type RemoteExecTasks } from "./remote-exec-tasks.js"
import { makeWorkspaceSyncs, type WorkspaceSyncs } from "./workspace-syncs.js"

export interface RemoteWorkServices {
  readonly execTasks: ExecTasks
  readonly remoteExecTasks: RemoteExecTasks
  readonly mirrors: MirrorStore
  readonly workspaceSyncs: WorkspaceSyncs
  readonly orphanSweep: OrphanSweep
}

export const makeRemoteWorkServices = (
  dataDir: string,
  link: Pick<MachineLink, "invoke" | "isGone">,
  self: MirrorTransportSelf
): RemoteWorkServices => {
  const execTasks = makeExecTasks({
    directory: join(dataDir, "exec-tasks"),
    shell: process.env.SHELL || "/bin/sh",
    env: process.env
  })
  const remoteExecTasks = makeRemoteExecTasks({ self, link, local: execTasks })
  const mirrors = makeMirrorStore(join(dataDir, "mirrors"))
  const workspaceSyncs = makeWorkspaceSyncs({
    directory: dataDir,
    transport: fleetMirrorTransport(link, self)
  })
  const orphanSweep = makeOrphanSweep({
    isGone: link.isGone,
    mirrors,
    execTasks,
    remoteExecTasks,
    workspaceSyncs
  })
  return { execTasks, remoteExecTasks, mirrors, workspaceSyncs, orphanSweep }
}
