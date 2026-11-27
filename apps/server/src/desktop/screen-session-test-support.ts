export const ownUid = 1000

export interface Process {
  readonly uid?: number
  readonly env?: Record<string, string>
  readonly session?: string
  readonly started?: number
  readonly comm?: string
  readonly parent?: number
  readonly cmdline?: ReadonlyArray<string>
}

export interface Machine {
  readonly processes: Record<number, Process>
  readonly liveDisplays?: ReadonlyArray<string>
  readonly answers?: Record<string, { readonly code?: number; readonly output: string }>
}

export const machine = ({ processes, liveDisplays = ["X0"], answers = {} }: Machine) => ({
  uid: ownUid,
  listFolder: (path: string): ReadonlyArray<string> => {
    if (path === "/proc") return [...Object.keys(processes), "self", "cpuinfo"]
    return path === "/tmp/.X11-unix" ? liveDisplays : []
  },
  readText: (path: string): string | undefined => {
    const [, pid, file] = /^\/proc\/(\d+)\/(\w+)$/.exec(path) ?? []
    const process = processes[Number(pid)]
    return process === undefined ? undefined : procFile(Number(pid), process, file ?? "")
  },
  run: async (command: string, args: ReadonlyArray<string>) => {
    const answer = answers[[command, ...args].join(" ")]
    return { code: answer?.code ?? (answer === undefined ? 127 : 0), output: answer?.output ?? "" }
  }
})

const procFile = (pid: number, process: Process, file: string): string | undefined => {
  if (file === "status")
    return `Name:\tx\nPPid:\t${process.parent ?? 1}\nUid:\t${process.uid ?? ownUid}\t0\t0\t0\n`
  if (file === "environ") return pairs(process.env ?? {})
  if (file === "cgroup")
    return `0::/user.slice/user-${process.uid ?? ownUid}.slice/session-${process.session ?? "none"}.scope\n`
  if (file === "stat") return `${pid} (x) S ${"0 ".repeat(18)}${process.started ?? 0} 0 0\n`
  if (file === "comm") return `${process.comm ?? "x"}\n`
  return file === "cmdline" ? (process.cmdline ?? []).join("\0") : undefined
}

const pairs = (env: Record<string, string>): string =>
  Object.entries(env)
    .map(([name, value]) => `${name}=${value}\0`)
    .join("")
