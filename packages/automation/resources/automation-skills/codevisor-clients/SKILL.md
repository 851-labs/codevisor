---
name: codevisor-clients
description: Use when the user asks to show, open, focus, or lay out something in the Codevisor app (a chat, a page, a file, a tab, a split, or the window itself), or when an agent's workspace or result should be put in front of them.
---

# Codevisor clients

A **client** is one open Codevisor window: a macOS window or the iOS app. The user may have several open at once, on different devices. Act on the one they're using, not on all of them.

```js
;async () => machines.current.clients.list()
// { items: [{ clientId, name, platform: "macos" | "ios", machine, online, isOrigin, lastActiveAt?,
//    viewing: { workspaceId?, agentId?, page?, panes? }, capabilities? }] }
```

- `isOrigin` marks the window that sent the message you're handling now. Automations and agents started by other agents have **no** origin, so don't assume one exists.
- `viewing` is what the window currently shows. It is absent when the window didn't answer in time; the window can still be addressed.
- `capabilities` says what the window supports. iOS has no free window geometry, for example.

Usually the right client is the origin, or the most recently active window on the device the user is using. Avoid acting on every client at once: panes appearing on the user's phone are rarely wanted.

## Acting on a client

```js
;async () => {
  const { items } = await machines.current.clients.list()
  const target =
    items.find((c) => c.isOrigin) ??
    items
      .filter((c) => c.online)
      .sort((a, b) => (b.lastActiveAt ?? "").localeCompare(a.lastActiveAt ?? ""))[0]
  if (!target) return "No Codevisor window is open"
  await target.navigate({ workspaceId, destination: { kind: "chat", id: agentId } }) // show a chat
  return target.context() // tabs, panes, and supported actions
}
```

`workspaceId` and `agentId` come from `machines.current.tools.codevisor.context.current()` (your own) or from `agents.start` and `agents.list` (other agents).

- `c.context()`: full layout, ids, and supported actions. Read it before calling `layout`.
- `c.navigate({ workspaceId, destination?: { kind: "chat" | "tab" | "pane" | "leaf", id } })`: open or select.
- `c.openPage({ page, … })`: home, a new chat, or settings.
- `c.layout({ action, … })`: new_tab, split, move, detach, resize, reorder_tabs, rename_tab. Panes are created in the background unless you pass `focus: true`.
- `c.window({ action, … })`: focus, minimize, fullscreen, frame, sidebar.

These wrap `machine.tools.codevisor.clients.*`; use `machine.tools.describe.tool` for full schemas. Clients on another machine: `(await machines.get("macbook")).clients.list()`.

## Opening a file, chat, or terminal as a pane

Panes are shared workspace content: a pane you add opens as its own tab on every device showing that workspace. Add one with `workspaces.pane_upsert`:

```js
;async () => {
  const hex = () => Math.floor(Math.random() * 16).toString(16)
  const paneId = "xxxxxxxx-xxxx-4xxx-8xxx-xxxxxxxxxxxx".replace(/x/g, hex)
  return machines.current.tools.codevisor.workspaces.pane_upsert({
    workspaceId,
    paneId,
    providerId: "codevisor",
    paneType: "markdown",
    title: "README.md",
    resourceKind: "file",
    resourceId: "/Users/me/repo/README.md"
  })
}
```

- `paneId` must be a new UUID. The call accepts any string, but the apps skip a pane whose id isn't a UUID. The sandbox has no `crypto`, so build the UUID yourself as above.
- Built-in panes use `providerId: "codevisor"` and `paneType` `chat`, `terminal`, `browser`, or `markdown`. A chat references `resourceKind: "session"` and its agent id; markdown references `resourceKind: "file"` and an absolute path.
- `workspaces.pane_close({ workspaceId, paneId })` removes it everywhere. To select it in one window, call `c.navigate` with `destination: { kind: "pane", id: paneId }`.

## Disconnects

A window can close at any moment. Calls on a closed window throw `ClientUnavailableError` with `{ clientId, clientName, phase }`. Re-list the clients and choose again rather than retrying the same id.

## Common mistakes

- Picking the first client in the list. Prefer the origin, then the most recently active online window.
- Guessing tab, pane, or leaf ids. Read them from `c.context()`.
- Using `c.layout` to open a file. `layout` arranges panes and opens empty New Tabs; `workspaces.pane_upsert` adds a pane with content.
