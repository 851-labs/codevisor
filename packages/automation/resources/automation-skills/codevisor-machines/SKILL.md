---
name: codevisor-machines
description: Run MCP tools, Codevisor tools, or agents on another of the user's machines (e.g. drive the MacBook's simulator or Xcode from a chat on the Mac Studio). Use when the user mentions another computer or machine by name, when a needed tool is only available elsewhere, or when work should run on a different machine.
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
