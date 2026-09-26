---
name: codevisor-clients
description: See and drive the Codevisor apps the user has open (macOS and iOS) — which windows exist, what each is showing, which one sent the current message — and navigate them, open pages, arrange panes and tabs, or control the window. Use when the user asks to show, open, focus, or lay out something in Codevisor, or when you want to put an agent's workspace or result in front of them.
---

# Codevisor clients

A **client** is one open Codevisor window: a macOS window or the iOS app. The user may have several open at once, on different devices.

```js
;async () => clients.list()
// [{ id, name, platform: "macos" | "ios", machine, online, isOrigin, lastActiveAt?,
//    viewing: { workspaceId?, sessionId?, page?, panes? }, capabilities? }]
```

- `isOrigin` marks the window that sent the message you're handling now. Automations and agents started by other agents have **no** origin, so don't assume one exists.
- `viewing` is what the window currently shows.
- `capabilities` says what the window supports. iOS has no free window geometry, for example.

You decide which client to act on. Usually it's the origin, or the most recently active window on the device the user is using. Avoid acting on every client at once: panes appearing on the user's phone are rarely wanted.

## Acting on a client

```js
;async () => {
  const all = await clients.list()
  const target =
    all.find((c) => c.isOrigin) ??
    all.sort((a, b) => (b.lastActiveAt ?? "").localeCompare(a.lastActiveAt ?? ""))[0]
  if (!target) return "No Codevisor window is open"
  await target.navigate({ workspaceId, destination: { kind: "chat", id: sessionId } }) // show a chat
  return target.context() // tabs, panes, and supported actions
}
```

- `c.context()`: full layout, ids, and supported actions. Read it before calling `layout`.
- `c.navigate({ workspaceId, destination?: { kind: "chat" | "tab" | "pane" | "leaf", id } })`: open or select.
- `c.openPage({ page, … })`: home, a new chat, or settings.
- `c.layout({ action, … })`: new_tab, split, move, detach, resize, reorder_tabs, rename_tab. Panes are created in the background unless you pass `focus: true`.
- `c.window({ action, … })`: focus, minimize, fullscreen, frame, sidebar.

These wrap `tools.codevisor.clients.*`; use `tools.describe.tool` for full schemas. Clients on another machine: `(await machines.get("macbook")).clients.list()`.

## Disconnects

A window can close at any moment. Calls on a closed window throw `ClientUnavailableError` with `{ clientId, clientName, phase }`. Re-list the clients and choose again rather than retrying the same id.
