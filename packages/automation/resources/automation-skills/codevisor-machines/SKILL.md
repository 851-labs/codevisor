---
name: codevisor-machines
description: Run MCP tools, Codevisor tools, or agents on another of the user's machines (e.g. drive the MacBook's simulator or Xcode from a chat on the Mac Studio), and add or remove machines on the account (e.g. set up a new VPS as a Codevisor machine over SSH). Use when the user mentions another computer or machine by name, when a needed tool is only available elsewhere, when work should run on a different machine, or when a server or computer should become (or stop being) a Codevisor machine.
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
- `machines.current.tools.codevisor.machines.create_sandbox({ profileId, projectId })` starts a throwaway sandbox from one of the user's sandbox profiles (`machines.current.tools.codevisor.machines.list_sandbox_profiles()`; each names a vendor such as Tart, E2B or Modal and an image) with a workspace for that project and this machine's harnesses, skills, MCPs and sign-ins copied over one way. It's ready in a few minutes (`machines.current.tools.codevisor.machines.list_sandboxes()`), costs money while it runs, and is destroyed when its workspace is archived or with `machines.current.tools.codevisor.machines.destroy_sandbox({ sandboxId, confirm })`. Sandboxes carry `ephemeral` on their `machines.list()` handles.

The CLI does the same things through the same routes: `codevisor machines add|invite|list|remove`.
