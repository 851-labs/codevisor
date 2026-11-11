---
name: codevisor-machines
description: Use when the user mentions another computer or machine by name, when a needed tool exists only on another machine (e.g. the MacBook's simulator or Xcode from a chat on the Mac Studio), when a command must run on another machine against your workspace (Swift tests on a Mac from a Linux chat), when work should run on a different machine or a throwaway sandbox (E2B, Modal, Vercel, Daytona, Tart, Apple Containers), or when a server or computer should become, or stop being, a Codevisor machine.
---

# Codevisor machines

There are two ways to work on another of the user's machines. Codevisor's own tools are globals that take a `machine`: `agents.start({ …, machine: "macbook" })`, `projects.list({ machine: "macbook" })`. Everything else that belongs to a machine hangs off its machine object: `machines.current` for the machine this chat runs on, and `await machines.get("macbook")` for another. Your script still runs here; only the tool calls travel, so one script can combine machines, for example building on one and reading the result on another.

```js
;async () => {
  const { items } = await machines.list()
  // [{ machineId, name, os?, online, lastSeen?, isCurrent }]
  const mbp = await machines.get("macbook") // machineId, exact name, or unique name prefix
  const hits = await mbp.tools.search({ query: "simulator screenshot" })
  return hits.items.map((item) => item.path ?? item.name)
}
```

- `m.tools.<server>.<tool>(args)`, `m.tools.search(…)`, and `m.tools.describe.tool(…)` run plugin and MCP tools on machine `m`, with that machine's MCPs and credentials.
- `agents.start({ …, machine: m })` starts an agent on that machine, linked to you (see `codevisor-agents`). Every other Codevisor tool that acts on one machine takes `machine` the same way. A machine is a `Machine`, its `machineId`, or its name.
- `agents.start({ checkout: "none", machine: m, title, prompt })` starts a throwaway chat on `m` in a fresh empty folder, without adding a project there. Use it when you just need that machine's tools, or it has no projects.
- `m.clients.list()` lists apps connected to that machine (see `codevisor-clients`).
- `m.exec(…)`, `m.readFile(…)` and `m.taskStop(…)` run shell commands and read files on `m` (see below).
- `machines.current.tools.search({ query, machines: "all" })` searches every online machine. Each result has `machine: { machineId, name }`.

## Running commands on a machine

`m.exec` works like a terminal on that machine, with the same options as a local shell tool:

```js
;async () => {
  const mac = await machines.get("macbook")
  const result = await mac.exec({
    command: "xcrun simctl list devices booted",
    description: "List booted simulators"
  })
  return result // { exitCode, output, timedOut, durationMs, outputPath }
}
```

- `command` and a short `description`; `timeout` in ms (default 120000, max 600000); `cwd` (default the home folder there).
- `output` combines stdout and stderr and keeps only the last 30000 characters. The full log is at `outputPath`: read it with `mac.readFile({ path, offset?, limit? })`, which returns numbered lines (2000 by default).
- `run_in_background: true` returns `{ taskId, outputPath }` at once. When the task exits you get an `exec.task_finished` event with the end of its output. Stop it with `mac.taskStop(taskId)`. It keeps running across turns, shows in the user's inspector (where they can stop it), and is stopped when the workspace is archived.
- Commands run as the user in a login shell, outside your workspace. To run against your own files, mirror the workspace first.

## Mirroring your workspace to another machine

A workspace mirror is a one-way copy of this chat's workspace on another machine, kept current in the background. `workspace.startMirror(machine)` creates it; it lasts through later turns and restarts until you call `workspace.stopMirror(machine)` or the workspace is archived. Run commands there with `cwd` set to the mirror's `path`:

```js
;async () => {
  const mac = await machines.get("macbook")
  const mirror = await workspace.startMirror(mac) // { path, state: "syncing" }
  await workspace.waitForMirror(mac) // returns once your latest edits are there
  return mac.exec({
    command: "swift test",
    cwd: mirror.path,
    description: "Run Swift tests",
    timeout: 600000
  })
}
```

- A mirror is one way and follows `.gitignore`: edits here reach it within about a second, and files over 50 MB are skipped (listed in `skipped`). Files the other machine creates, like build output or `node_modules`, stay there and are never sent back. Bring results back with `mac.readFile`.
- A new mirror starts with source files only, like a fresh clone: run the project's setup there once (`bun install`, resolving packages).
- The mirror is a git checkout at the same commit and branch, with your uncommitted edits as changes and no older history, so git-aware tools and build caches (turbo) work there. Don't commit in it: the next sync resets it, and nothing comes back.
- After editing, call `workspace.waitForMirror(machine)` before a command that must see the edit. `exec` adds a `mirrorBehind` note when it ran in a mirror that was behind.
- `workspace.mirrorStatus(machine)` gives `state` (`syncing`, `synced`, `failed`), `pendingChanges`, `lastSyncedAt`, `lastSync`, `skipped` and `error`. `workspace.mirrors()` lists every mirror of the workspace.
- Mirroring to a sandbox doesn't work: `workspace.startMirror(sandbox)` fails with code `sandbox_target`. To run something on a sandbox, use `exec` there without a mirror.
- Mirroring from a sandbox does work: when your chat runs on a sandbox, `workspace.startMirror(machine)` mirrors its workspace to any of the user's own (non-sandbox) machines, like their Mac.
- `workspace.stopMirror(machine)` deletes the mirror from that machine (later, if it's offline). Stop it when the work there is done; the user can also remove it from the inspector's Mirrors section.

## Disconnects

`machines.get` returns a machine even when it's offline; check `online` before starting long work there. A call to an unreachable machine throws `MachineUnavailableError` with `{ machineId, machineName, lastSeen, phase }`:

- `phase: "before-send"`: the machine was offline and nothing ran. It is safe to retry later or use another machine.
- `phase: "in-flight"`: the connection dropped mid-call and the tool may or may not have completed. Check the result (for example with a read-only tool) before repeating anything with side effects.

```js
;async () => {
  try {
    const macbook = await machines.get("macbook")
    return await macbook.tools.xcode.build({ scheme: "App" })
  } catch (error) {
    if (error instanceof MachineUnavailableError) return `MacBook unavailable (${error.phase})`
    throw error
  }
}
```

## Adding a machine

`machines.add` sets a host up end to end, with no approval step: from this machine (with its SSH keys and `~/.ssh/config`) it installs Codevisor on the host, joins it to the account with a one-time invite, and waits until it's online.

```js
;async () => {
  status("Installing Codevisor on the new server")
  const { machine } = await machines.add({
    ssh: "root@203.0.113.7",
    name: "hetzner-1"
  })
  return machine // also in machines.list() items from now on
}
```

- The host needs key-based SSH from this machine and `curl`. Provision the server (or add your key to it) first; it never prompts for a password.
- Codevisor never runs as root. Over `root@` SSH it runs as a `codevisor` account it creates, with passwordless `sudo`; over another account, as that account.
- It takes a few minutes. Failures come back with the host's output: fix the cause (SSH access, firewall, a missing `curl`) and call it again.
- When SSH isn't the way in (cloud-init user data, a web console, a container), use `machines.invite()` for a one-time code (about 10 minutes, one use). Install with `CODEVISOR_INVITE=<code>` set (`curl -fsSL https://www.codevisor.dev/install.sh | CODEVISOR_INVITE=… sh`), or run `codevisor auth login --invite -` with the code on stdin. The code is a secret: don't show it to the user or leave it in files.
- `machines.remove({ machineId, confirm })` removes another machine; pass `confirm: true` only after the user approves. A machine removes itself with `codevisor auth logout`.

The CLI does the same things through the same routes: `codevisor machines add|invite|list|remove`.

## Sandboxes

`sandboxes.*` manages throwaway machines from a vendor (Tart VMs or Apple Linux containers on a Mac, E2B, Modal, Vercel, Daytona, Tart Orchard). Each sandbox installs Codevisor, joins the account, gets this machine's harnesses, skills, MCPs and sign-ins copied over one way, and clones one project into its own workspace. Sandboxes cost the user money while they run, and carry `ephemeral: { provider, ownerDeviceId }` on their `machines.list()` items.

- **Vendors:** `sandboxes.vendors()` lists each vendor's `accountFields` (credentials, or the Mac that runs Tart) and `profileFields` (image, `cpu`, `memoryGiB`, lifetime…) with defaults and limits, plus this machine's `capabilities` and CPU/memory `maximums`.
- **Providers** (a vendor plus its credentials or Mac): `sandboxes.providers_list()`, `providers_create({ provider, label?, values })`, `providers_update({ accountId, provider, values })`, `providers_delete({ accountId, confirm })`.
  - Credentials are checked with the vendor before saving, and secrets are never returned: `secretsSet` only names the stored secret fields. Never repeat a secret back to the user or write it to a file.
  - Vercel needs just `{ token }` (a 409 `sandboxChoiceNeeded` asks for a team when the token reaches several). Tart needs `{ machineId }` of an Apple silicon Mac; Codevisor installs its own Tart there on first use.
- **Profiles** (what to start: provider, image, size): `sandboxes.profiles_list()`, `profiles_availability()` (which ones this machine can start now, with a `disabledReason` for the rest), `profiles_create({ name, provider, accountId?, values })`, `profiles_update({ profileId, … })` (send every value to keep), `profiles_delete({ profileId, confirm })`. CPU and memory are checked against the vendor's limits and, for Tart, this Mac's hardware.
- **Sandboxes:**
  - `sandboxes.create({ profileId, projectId, name?, harnessId? })` returns at once with `state: "creating"`.
  - `sandboxes.wait({ sandboxId, timeoutMs? })` blocks until it is `ready` or `failed`, or returns `timedOut: true` (call it again), since execute code has no `setTimeout` to poll with. On the way `state` moves through `creating`, `bootstrapping`, `syncing` and `cloning`, and `steps` time each stage.
  - A ready sandbox has `machineId` (use it with `machines.get(machineId)`), `remoteProjectId` and `workspaceId`; a failed one has `error`.
  - `sandboxes.get({ sandboxId })` reads it without waiting, `sandboxes.log({ sandboxId, last? })` reads its start log, `sandboxes.retry({ sandboxId })` starts a failed one again, and `sandboxes.list()` lists them all.
  - Archiving its workspace, or `sandboxes.destroy({ sandboxId, confirm })`, deletes the vendor's machine. Unpushed work is lost, so confirm with the user first.
- **An agent on a new sandbox:** `agents.start({ sandbox, project, harness?, title, prompt })` creates the sandbox and starts the agent there once it's ready (see `codevisor-agents`).
- Sandboxes and `machines.*` are shared by all your machines, so they take no `machine`.

```js
;async () => {
  const { projectId } = await context.current()
  const { items: providers } = await sandboxes.providers_list()
  const e2b = providers.find((provider) => provider.provider === "e2b")
  const profile = await sandboxes.profiles_create({
    name: "E2B small",
    provider: "e2b",
    accountId: e2b.accountId,
    values: { timeoutMinutes: 60 }
  })
  const { sandboxId } = await sandboxes.create({ profileId: profile.profileId, projectId })
  status("Starting the sandbox")
  const sandbox = await sandboxes.wait({ sandboxId, timeoutMs: 300000 })
  if (sandbox.state === "failed")
    return { error: sandbox.error, log: await sandboxes.log({ sandboxId, last: 20 }) }
  return sandbox // timedOut: true means it is still starting; wait again
}
```

## Common mistakes

- Repeating a side-effecting call after an `"in-flight"` disconnect without checking whether it already ran.
- Starting long work on a machine without checking `online` first.
- Running a command in a mirror right after an edit without `workspace.waitForMirror(machine)`, then debugging old code.
- Expecting files built on the other machine to appear in your workspace; read them with `m.readFile` instead.
- Passing `confirm: true` to `machines.remove`, `sandboxes.destroy`, or a `*_delete` tool before the user has approved it.
- Leaving a sandbox running after its work is pushed. It costs the user money until it is archived or destroyed.
