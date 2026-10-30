import { spawn } from "node:child_process"
import { randomUUID } from "node:crypto"
import { chmod, mkdtemp, rm, stat, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { afterEach, describe, expect, it } from "vitest"

import {
  DAYTONA_DEFINITION,
  DAYTONA_SETUP_COMMANDS,
  daytonaAdapter,
  makeDaytonaProvider,
  type DaytonaClient,
  type DaytonaCredentials,
  type DaytonaSandboxInfo
} from "./daytona.js"
import { readAccountValues, readProfileOptions } from "./options.js"
import type { ExecResult } from "./provider.js"

const spec = { name: "box", tags: { owner: "device-a", machine: "m1" } }
const ok: ExecResult = { exitCode: 0, stdout: "ok", stderr: "" }
const tagged = { "codevisor-owner": "device-a", "codevisor-machine": "m1" }

const fakeDaytona = (sandboxes: DaytonaSandboxInfo[] = [], email?: string) => {
  const calls: unknown[] = []
  const client: DaytonaClient = {
    create: (request, onLog) => {
      calls.push({ create: request })
      onLog("Building image")
      return Promise.resolve({ id: "sb-1", state: "started", labels: request.labels })
    },
    upload: (sandboxId, path, content) => {
      calls.push({ upload: sandboxId, path, content })
      return Promise.resolve()
    },
    run: (sandboxId, command, timeoutMs) => {
      calls.push({ run: sandboxId, command, timeoutMs })
      return Promise.resolve(ok)
    },
    info: (sandboxId) => Promise.resolve(sandboxes.find((sandbox) => sandbox.id === sandboxId)),
    start: (sandboxId) => {
      calls.push({ start: sandboxId })
      return Promise.resolve()
    },
    stop: (sandboxId) => {
      calls.push({ stop: sandboxId })
      return Promise.resolve()
    },
    remove: (sandboxId) => {
      calls.push({ remove: sandboxId })
      return Promise.resolve()
    },
    list: (labels) => {
      calls.push({ list: labels })
      return Promise.resolve(sandboxes)
    },
    email: () => Promise.resolve(email)
  }
  return { client, calls }
}

const recordingProgress = () => {
  const lines: string[] = []
  const progress = {
    stage: () => {},
    log: (line: string) => {
      lines.push(line)
    },
    output: () => {}
  }
  return { progress, lines }
}

describe("Daytona provider", () => {
  it("builds the image with Codevisor's packages, sized and labelled, and never auto-stops", async () => {
    const { client, calls } = fakeDaytona()
    const provider = makeDaytonaProvider(client)
    const { progress, lines } = recordingProgress()

    const created = await provider.create(
      spec,
      readProfileOptions(DAYTONA_DEFINITION, {}),
      progress
    )

    expect(created).toEqual({ providerMachineId: "sb-1", platform: "linux" })
    expect(calls).toEqual([
      {
        create: {
          source: {
            kind: "image",
            image: "debian:bookworm-slim",
            setupCommands: DAYTONA_SETUP_COMMANDS,
            resources: { cpu: 2, memory: 4, disk: 10 }
          },
          labels: tagged,
          autoStopMinutes: 0
        }
      }
    ])
    expect(DAYTONA_SETUP_COMMANDS[0]).toContain("curl ca-certificates git sudo")
    expect(lines).toEqual(["Building image"])
  })

  it("starts from a snapshot when one is set", async () => {
    const { client, calls } = fakeDaytona()
    const provider = makeDaytonaProvider(client)
    const options = readProfileOptions(DAYTONA_DEFINITION, { snapshot: "codevisor-base" })

    const created = await provider.create(spec, options)

    expect(created).toEqual({ providerMachineId: "sb-1", platform: "linux" })
    expect(calls).toEqual([
      {
        create: {
          source: { kind: "snapshot", snapshot: "codevisor-base" },
          labels: tagged,
          autoStopMinutes: 0
        }
      }
    ])
  })

  it("falls back to the documented sizes when options are missing", async () => {
    const { client, calls } = fakeDaytona()

    await makeDaytonaProvider(client).create(spec, { image: "ubuntu:22.04" })

    expect(calls).toEqual([
      {
        create: {
          source: {
            kind: "image",
            image: "ubuntu:22.04",
            setupCommands: DAYTONA_SETUP_COMMANDS,
            resources: { cpu: 2, memory: 4, disk: 10 }
          },
          labels: tagged,
          autoStopMinutes: 0
        }
      }
    ])
  })

  it("caps resources at the default organization limits", () => {
    expect(() => readProfileOptions(DAYTONA_DEFINITION, { cpu: 5 })).toThrow(
      "CPUs must be between 1 and 4"
    )
    expect(() => readProfileOptions(DAYTONA_DEFINITION, { memoryGiB: 9 })).toThrow(
      "Memory (GiB) must be between 1 and 8"
    )
    expect(() => readProfileOptions(DAYTONA_DEFINITION, { diskGiB: 11 })).toThrow(
      "Disk (GiB) must be between 1 and 10"
    )
  })

  it("runs scripts as root from /dev/null with a timeout in whole seconds", async () => {
    const { client, calls } = fakeDaytona()
    const provider = makeDaytonaProvider(client)

    await provider.exec("sb-1", { script: "id" })
    await provider.exec("sb-1", { script: "id", timeoutMs: 1 })

    expect(calls).toEqual([
      { run: "sb-1", command: rootCommand("id", 600, "/dev/null"), timeoutMs: 600_000 },
      { run: "sb-1", command: rootCommand("id", 1, "/dev/null"), timeoutMs: 1 }
    ])
  })

  it("uploads stdin to a file the command reads and then removes", async () => {
    const { client, calls } = fakeDaytona()
    const provider = makeDaytonaProvider(client, () => "abc")

    await provider.exec("sb-1", { script: "cat", stdin: "invite\n", timeoutMs: 1500 })

    const path = "/tmp/codevisor-stdin-abc"
    expect(calls).toEqual([
      { upload: "sb-1", path, content: "invite\n" },
      { run: "sb-1", command: rootCommand("cat", 2, path, [`rm -f '${path}'`]), timeoutMs: 1500 }
    ])
  })

  it("maps sandbox states so stopped and archived ones resume and only dead ones are gone", async () => {
    const names = [
      "started",
      "creating",
      "stopping",
      "stopped",
      "archived",
      "paused",
      "destroyed",
      "destroying",
      "error",
      "build_failed",
      "hibernating"
    ]
    const sandboxes = [
      ...names.map((state) => ({ id: state, state, labels: {} })),
      { id: "stateless", labels: {} }
    ]
    const provider = makeDaytonaProvider(fakeDaytona(sandboxes).client)
    const ids = [...names, "stateless", "missing"]

    const states = await Promise.all(ids.map(async (id) => (await provider.status(id)).state))

    expect(Object.fromEntries(ids.map((id, index) => [id, states[index]]))).toEqual({
      started: "running",
      creating: "starting",
      stopping: "starting",
      stopped: "stopped",
      archived: "stopped",
      paused: "stopped",
      destroyed: "gone",
      destroying: "gone",
      error: "gone",
      build_failed: "gone",
      hibernating: "starting",
      stateless: "starting",
      missing: "gone"
    })
  })

  it("lists labelled sandboxes by owner, starts stopped ones and deletes them", async () => {
    const { client, calls } = fakeDaytona([
      { id: "sb-1", state: "started", labels: tagged },
      { id: "sb-2", state: "started", labels: { "codevisor-owner": "device-a" } }
    ])
    const provider = makeDaytonaProvider(client)

    const listed = await provider.list("device-a")
    await provider.resume?.("sb-1")
    await provider.destroy("sb-1")

    expect(listed).toEqual([
      { providerMachineId: "sb-1", tags: { owner: "device-a", machine: "m1" } }
    ])
    expect(calls).toEqual([
      { list: { "codevisor-owner": "device-a" } },
      { start: "sb-1" },
      { remove: "sb-1" }
    ])
  })

  it("pauses by stopping the sandbox and wakes by starting it again", async () => {
    const { client, calls } = fakeDaytona()
    const pausing = makeDaytonaProvider(client).pausing

    const paused = await pausing?.pause("sb-1")
    const woken = await pausing?.wake({ providerMachineId: "sb-1" }, spec, {})

    expect([paused, woken]).toEqual([{ providerMachineId: "sb-1" }, { providerMachineId: "sb-1" }])
    expect(calls).toEqual([{ stop: "sb-1" }, { start: "sb-1" }])
  })
})

describe("Daytona root command", () => {
  const scratch: string[] = []

  afterEach(async () => {
    await Promise.all(scratch.splice(0).map((path) => rm(path, { recursive: true, force: true })))
  })

  const stubBin = async (uid: string): Promise<string> => {
    const dir = await mkdtemp(join(tmpdir(), "codevisor-daytona-"))
    scratch.push(dir)
    await stub(dir, "id", `echo ${uid}`)
    await stub(dir, "timeout", 'echo "timeout $1 $2 $3" >&2; shift 3; exec "$@"')
    await stub(dir, "sudo", 'echo "sudo $1" >&2; shift; exec "$@"')
    return dir
  }

  const runLocally = async (uid: string, script: string, stdin?: string) => {
    const bin = await stubBin(uid)
    const id = randomUUID()
    const stdinPath = `/tmp/codevisor-stdin-${id}`
    scratch.push(stdinPath)
    const commands: string[] = []
    const local: DaytonaClient = {
      ...fakeDaytona().client,
      upload: (_sandboxId, path, content) => writeFile(path, content),
      run: (_sandboxId, command) => {
        commands.push(command)
        return Promise.resolve(ok)
      }
    }
    const provider = makeDaytonaProvider(local, () => id)
    await provider.exec("sb-1", {
      script,
      timeoutMs: 30_000,
      ...(stdin === undefined ? {} : { stdin })
    })
    return { result: await shell(commands.join(""), bin), stdinPath }
  }

  it("keeps the script's quoting, feeds stdin, returns its exit code and removes the stdin file", async () => {
    const { result, stdinPath } = await runLocally(
      "0",
      `printf '%s|' "it's"; cat; exit 3`,
      "invite\n"
    )

    expect(result).toEqual({
      exitCode: 3,
      stdout: "it's|invite\n",
      stderr: "timeout -s KILL 30\n"
    })
    await expect(stat(stdinPath)).rejects.toThrow("ENOENT")
  })

  it("elevates with non-interactive sudo when the sandbox user is not root", async () => {
    const { result } = await runLocally("1000", "echo hi")

    expect(result).toEqual({ exitCode: 0, stdout: "hi\n", stderr: "sudo -n\ntimeout -s KILL 30\n" })
  })
})

describe("Daytona adapter", () => {
  it("connects with the API key, the default API URL and an optional region", () => {
    const credentials: DaytonaCredentials[] = []
    const adapter = daytonaAdapter((given) => {
      credentials.push(given)
      return fakeDaytona().client
    })

    adapter.connect(readAccountValues(DAYTONA_DEFINITION, { apiKey: "key-1" }))
    adapter.connect({ apiKey: "key-2", apiUrl: "https://daytona.example/api", target: "eu" })
    adapter.connect({ apiKey: "key-3" })

    expect(credentials).toEqual([
      { apiKey: "key-1", apiUrl: "https://app.daytona.io/api" },
      { apiKey: "key-2", apiUrl: "https://daytona.example/api", target: "eu" },
      { apiKey: "key-3", apiUrl: "https://app.daytona.io/api" }
    ])
  })

  it("verifies with a harmless list and names the account by its email", async () => {
    const { client, calls } = fakeDaytona([], "dylan@851.sh")

    const identity = await daytonaAdapter(() => client).verify?.({ apiKey: "key-1" })

    expect(identity).toEqual({ identity: "dylan@851.sh" })
    expect(calls).toEqual([{ list: { "codevisor-owner": "codevisor-verify" } }])
  })

  it("verifies without an identity when the key cannot read the user", async () => {
    const identity = await daytonaAdapter(() => fakeDaytona().client).verify?.({ apiKey: "k" })

    expect(identity).toEqual({})
  })
})

const rootCommand = (
  script: string,
  seconds: number,
  input: string,
  cleanup: ReadonlyArray<string> = []
): string => {
  const lines = [
    'as_root() { if [ "$(id -u)" = 0 ]; then "$@"; else sudo -n "$@"; fi; }',
    `as_root timeout -s KILL ${seconds} sh -c '${script}' <'${input}'`,
    "status=$?",
    ...cleanup,
    "exit $status"
  ]
  return `sh -c '${lines.join("\n").replaceAll("'", `'\\''`)}'`
}

const stub = async (dir: string, name: string, body: string): Promise<void> => {
  const path = join(dir, name)
  await writeFile(path, `#!/bin/sh\n${body}\n`)
  await chmod(path, 0o755)
}

const shell = (command: string, bin: string): Promise<ExecResult> =>
  new Promise((resolve, reject) => {
    const child = spawn("/bin/sh", ["-c", command], { env: { PATH: `${bin}:/usr/bin:/bin` } })
    const output = { stdout: "", stderr: "" }
    child.stdout.setEncoding("utf8").on("data", (chunk: string) => {
      output.stdout += chunk
    })
    child.stderr.setEncoding("utf8").on("data", (chunk: string) => {
      output.stderr += chunk
    })
    child.on("error", reject)
    child.on("close", (code) => {
      resolve({ exitCode: code ?? -1, ...output })
    })
  })
