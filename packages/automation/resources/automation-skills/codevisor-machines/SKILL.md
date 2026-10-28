---
name: codevisor-machines
description: Run MCP tools, Codevisor tools, or agents on another of the user's machines (e.g. drive the MacBook's simulator or Xcode from a chat on the Mac Studio), add or remove machines on the account (e.g. set up a new VPS as a Codevisor machine over SSH), and manage sandboxes: providers, profiles with CPU and memory limits, and throwaway sandbox machines (start, follow, retry, destroy). Use when the user mentions another computer or machine by name, when a needed tool is only available elsewhere, when work should run on a different machine, when a server or computer should become (or stop being) a Codevisor machine, or when work should run on a sandbox.
---

# Codevisor machines

Every call goes through a machine handle. `machines.current` is the machine this chat runs on, and other machines on the user's account expose the same kind of object.

```js
;async () => {
  const { items } = await machines.list()
  // [{ machineId, name, os?, online, lastSeen?, isCurrent }]
  const mbp = await machines.get("macbook") // machineId, exact name, or unique name prefix
  const hits = await mbp.tools.search({ query: "simulator screenshot" })
  return hits.items.map((item) => item.path ?? item.name)
}
```

- `m.tools.<server>.<tool>(args)`, `m.tools.search(…)`, and `m.tools.describe.tool(…)` run on machine `m`, with that machine's MCPs and credentials.
- `m.agents.*` starts and coordinates agents on that machine (see `codevisor-agents`). `m.tools.codevisor.*` controls the rest of Codevisor there.
- `m.clients.list()` lists apps connected to that machine (see `codevisor-clients`).
- `machines.current.tools.search({ query, machines: "all" })` searches every online machine. Each result has `machine: { machineId, name }`.

Your script still runs here; only the tool calls travel. You can combine machines in one script, for example building on one and reading the result on another.

## Disconnects

A call to an unreachable machine throws `MachineUnavailableError` with `{ machineId, machineName, lastSeen, phase }`:

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

Check `online` in `machines.list()` items before starting long work on another machine.

## Adding a machine

`machines.current.tools.codevisor.machines.add` sets a host up end to end, with no approval step: from this machine (with its SSH keys and `~/.ssh/config`) it installs Codevisor on the host, joins it to the account with a one-time invite, and waits until it's online.

```js
;async () => {
  status("Installing Codevisor on the new server")
  const { machine } = await machines.current.tools.codevisor.machines.add({
    ssh: "root@203.0.113.7",
    name: "hetzner-1"
  })
  return machine // also in machines.list() items from now on
}
```

- The host needs key-based SSH from this machine and `curl`. Provision the server (or add your key to it) first; it never prompts for a password.
- Codevisor never runs as root. Over `root@` SSH it runs as a `codevisor` account it creates, with passwordless `sudo`; over another account, as that account.
- It takes a few minutes. Failures come back with the host's output: fix the cause (SSH access, firewall, a missing `curl`) and call it again.
- When SSH isn't the way in (cloud-init user data, a web console, a container), use `machines.current.tools.codevisor.machines.invite` for a one-time code (about 10 minutes, one use). Install with `CODEVISOR_INVITE=<code>` set (`curl -fsSL https://www.codevisor.dev/install.sh | CODEVISOR_INVITE=… sh`), or run `codevisor auth login --invite -` with the code on stdin. The code is a secret: don't show it to the user or leave it in files.
- `machines.current.tools.codevisor.machines.remove({ machineId, confirm })` removes another machine; confirm with the user first. A machine removes itself with `codevisor auth logout`.
- Sandboxes carry `ephemeral: { provider, ownerDeviceId }` on their `machines.list()` items.

The CLI does the same things through the same routes: `codevisor machines add|invite|list|remove`.

## Sandboxes

`machines.current.tools.codevisor.sandboxes.*` manages throwaway machines from a vendor (Tart VMs on a Mac, E2B, Modal, Vercel, Daytona, Tart Orchard). Each sandbox installs Codevisor, joins the account, gets this machine's harnesses, skills, MCPs and sign-ins copied over one way, and clones one project into its own workspace. Sandboxes cost the user money while they run.

- **Vendors:** `sandboxes.vendors()` lists each vendor's `accountFields` (credentials, or the Mac that runs Tart) and `profileFields` (image, `cpu`, `memoryGiB`, lifetime…) with defaults and limits, plus this machine's `capabilities` and CPU/memory `maximums`.
- **Providers** (a vendor plus its credentials or Mac): `sandboxes.providers_list()`, `providers_create({ provider, label?, values })`, `providers_update({ accountId, provider, values })`, `providers_delete({ accountId, confirm })`. Credentials are checked with the vendor before saving, and secrets are never returned: `secretsSet` only names the stored secret fields. Vercel needs just `{ token }` (a 409 `sandboxChoiceNeeded` asks for a team when the token reaches several). Tart needs `{ machineId }` of an Apple silicon Mac; Codevisor installs its own Tart there on first use. Never repeat a secret back to the user or write it to a file.
- **Profiles** (what to start: provider, image, size): `sandboxes.profiles_list()`, `profiles_availability()` (which ones this machine can start now, with a `disabledReason` for the rest), `profiles_create({ name, provider, accountId?, values })`, `profiles_update({ profileId, … })` (send every value to keep), `profiles_delete({ profileId, confirm })`. CPU and memory are checked against the vendor's limits and, for Tart, this Mac's hardware.
- **Sandboxes:** `sandboxes.create({ profileId, projectId, name?, harnessId? })` returns at once with `state: "creating"`. `sandboxes.wait({ sandboxId, timeoutMs? })` blocks until it is `ready` or `failed` (or returns `timedOut: true`; call it again), since execute code has no `setTimeout` to poll with. On the way `state` moves through `creating`, `bootstrapping`, `syncing` and `cloning`, and `steps` time each stage. A ready sandbox has `machineId` (use it with `machines.get(machineId)`), `remoteProjectId` and `workspaceId`; a failed one has `error`. `sandboxes.get({ sandboxId })` reads it without waiting, `sandboxes.log({ sandboxId, last? })` reads its start log, `sandboxes.retry({ sandboxId })` starts a failed one again, and `sandboxes.list()` lists them all. Archiving its workspace, or `sandboxes.destroy({ sandboxId, confirm })`, deletes the vendor's machine; unpushed work is lost, so confirm first.
- **An agent on a new sandbox:** `machines.current.agents.start({ sandboxProfile, project, harness?, title, prompt, isolation: "project" })` creates the sandbox and starts the agent there once it's ready (see `codevisor-agents`).

```js
;async () => {
  const tools = machines.current.tools.codevisor
  const { items: providers } = await tools.sandboxes.providers_list()
  const e2b = providers.find((provider) => provider.provider === "e2b")
  const profile = await tools.sandboxes.profiles_create({
    name: "E2B small",
    provider: "e2b",
    accountId: e2b.accountId,
    values: { timeoutMinutes: 60 }
  })
  const { sandboxId } = await tools.sandboxes.create({ profileId: profile.profileId, projectId })
  status("Starting the sandbox")
  const sandbox = await tools.sandboxes.wait({ sandboxId, timeoutMs: 300000 })
  if (sandbox.state === "failed")
    return { error: sandbox.error, log: await tools.sandboxes.log({ sandboxId, last: 20 }) }
  return sandbox // timedOut: true means it is still starting; wait again
}
```
