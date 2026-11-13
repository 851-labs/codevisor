---
name: codevisor-plugins
description: Use when a task needs an outside service or app (Slack, Gmail, Linear, GitHub, Grafana, Notion, and the like), when you're unsure whether Codevisor can do something, or when the user asks you to find, install, connect, or sign in to a plugin. Also use it before telling the user something can't be done.
---

# Codevisor plugins

A **plugin** adds tools, events, skills, and panes to Codevisor, usually for one service. Plugins are shared by all the user's machines.

## Finding one

1. `plugins.search({ query })` searches installed plugins and the ones Codevisor can install. `ready` means installed, enabled, and signed in.
2. `plugins.describe({ plugin })` lists what one really offers: tools with their inputs, events, skills, and what signing in needs. Never promise a capability it doesn't list.
3. If it isn't installed or signed in, `plugins.request_setup({ plugin, reason })` shows the user a card to install it and sign in. `reason` is one plain sentence about what you'll do with it. It waits while they set it up and returns `connected`, `declined`, or `pending` (call it again to keep waiting). Don't ask the user for keys or tokens in chat.

## Using one

- **Tools:** call them through `execute` on a machine, like any tool. Find one with `machine.tools.search({ query })`, check its inputs with `machine.tools.describe.tool({ path })`, then call `machine.tools.<server>.<tool>(args)`. The `execute` skill covers this.
- **Skills:** a plugin can ship its own skills, named `<plugin>:<skill>`, like `linear:linear`. Read one with the `skills` tool before you use that plugin's tools for real work.
- **Events:** to be woken when something happens in the service, see `codevisor-events`.
- **Accounts:** a plugin can have several signed-in accounts, such as work and personal. `plugins.search` lists them. When there's more than one, its tools take an `account` argument (the account's label), and so does `events.subscribe`.
