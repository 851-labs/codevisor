---
name: codevisor-machines
description: Run MCP tools, Codevisor tools, or agents on another of the user's machines (e.g. drive the MacBook's simulator or Xcode from a chat on the Mac Studio), and add or remove machines on the account (e.g. set up a new VPS as a Codevisor machine over SSH). Use when the user mentions another computer or machine by name, when a needed tool is only available elsewhere, when work should run on a different machine, or when a server or computer should become (or stop being) a Codevisor machine.
---

# Codevisor machines

`tools` always means the machine this chat runs on. Other machines on the user's account expose the same kind of object.

```js
;async () => {
  const all = await machines.list()
  // [{ id, name, os?, online, lastSeen?, isCurrent }]
  const mbp = await machines.get("macbook") // id, exact name, or unique name prefix
  const hits = await mbp.tools.search({ query: "simulator screenshot" })
  return hits.items.map((item) => item.path)
}
```

- `machines.current` is this machine; `machines.current.tools === tools`.
- `m.tools.<server>.<tool>(args)`, `m.tools.search(…)` and `m.tools.describe.tool(…)` run on machine `m`, using that machine's MCPs and credentials.
- `m.tools.codevisor.*` controls Codevisor on that machine, including starting agents there (see `codevisor-agents`).
- `m.clients.list()` lists apps connected to that machine (see `codevisor-clients`).
- `tools.search({ query, machines: "all" })` searches every online machine. Each result has `machine: { id, name }`.

Your script still runs here; only the tool calls travel. You can combine machines in one script, for example building on one and reading the result on another.

## Disconnects

A call to an unreachable machine throws `MachineUnavailableError` with `{ machineId, machineName, lastSeen, phase }`:

- `phase: "before-send"`: the machine was offline and nothing ran. It is safe to retry later or use another machine.
- `phase: "in-flight"`: the connection dropped mid-call and the tool may or may not have completed. Check the result (for example with a read-only tool) before repeating anything with side effects.

```js
;async () => {
  try {
    return await (await machines.get("macbook")).tools.xcode.build({ scheme: "App" })
  } catch (error) {
    if (error instanceof MachineUnavailableError) return `MacBook unavailable (${error.phase})`
    throw error
  }
}
```

Check `online` in `machines.list()` before starting long work on another machine.

## Adding a machine

`machines.add` sets a host up end to end, with no approval step: from this machine (with its SSH keys and `~/.ssh/config`) it installs Codevisor on the host, joins it to the account with a one-time invite, and waits until it's online.

```js
;async () => {
  status("Installing Codevisor on the new server")
  const { machine } = await tools.codevisor.machines.add({
    ssh: "root@203.0.113.7",
    name: "hetzner-1"
  })
  return machine // also in machines.list() from now on
}
```

- The host needs key-based SSH from this machine and `curl`. Provision the server (or add your key to it) first; `machines.add` never prompts for a password.
- It takes a few minutes. Failures come back with the host's output: fix the cause (SSH access, firewall, a missing `curl`) and call it again.
- When SSH isn't the way in (cloud-init user data, a web console, a container), use `machines.invite` for a one-time code (about 10 minutes, one use). Install with `CODEVISOR_INVITE=<code>` set (`curl -fsSL https://www.codevisor.dev/install.sh | CODEVISOR_INVITE=… sh`), or run `codevisor auth login --invite -` with the code on stdin. The code is a secret: don't show it to the user or leave it in files.
- `machines.remove({ machineId, confirm })` removes another machine; confirm with the user first. A machine removes itself with `codevisor auth logout`.

The CLI does the same things through the same routes: `codevisor machines add|invite|list|remove`.
