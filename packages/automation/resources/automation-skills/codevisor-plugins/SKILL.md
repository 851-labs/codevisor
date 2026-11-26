---
name: codevisor-plugins
description: Use when a task needs an outside service or app (Slack, Gmail, Linear, GitHub, Grafana, Notion, and the like), when you're unsure whether Codevisor can do something, or when the user asks you to find, install, connect, or sign in to a plugin. Also use it before telling the user something can't be done.
---

# Codevisor plugins

A **plugin** adds tools, events, skills, and panes to Codevisor, usually for one service. Plugins are shared by all the user's machines.

## Finding one

1. `plugins.search({ query })` searches installed plugins and the ones Codevisor can install. `ready` means installed, turned on, and set up: signed in when the plugin needs an account, nothing more when it doesn't.
2. `plugins.describe({ plugin })` lists what one really offers: tools with their inputs, events, skills, and what signing in needs. Never promise a capability it doesn't list.
3. If it isn't `ready`, `plugins.request_setup({ plugin, reason })` shows the user a card in the chat. `reason` is one plain sentence about what you'll do with it. Don't ask the user for keys or tokens in chat.

## Setting one up

`plugins.request_setup` returns at once. It never waits for the user.

| `outcome`   | What it means                                                                                                                            | What you do                                                   |
| ----------- | ---------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------- |
| `ready`     | Already set up. No card was shown.                                                                                                       | Use the plugin.                                               |
| `requested` | The card is in the chat. `needs` is `install` (not installed yet) or `connect` (installed, but the user hasn't connected their account). | Say in one sentence what the card is for, then end your turn. |
| `disabled`  | Installed but turned off. No card was shown.                                                                                             | Ask the user to turn it on in Settings › Plugins.             |

- When `needs` is `connect`, say so: "You have Linear installed but haven't connected your account."
- The card stays in the chat and keeps working while the conversation goes on. Don't wait for it, poll `plugins.search`, or call `plugins.request_setup` again for the same plugin: asking twice shows no second card.
- When the plugin becomes ready, you get a hidden `<codevisor-event type="plugin.setup_finished" plugin="…" pluginId="…">` message. It starts a new turn when you're idle, or arrives at the end of your current turn. Then carry on with the task. It arrives however the user finished: from the card or from Settings.
- No event means the user hasn't finished. There is no "declined" event; if they ask for something else, help with that.

## Using one

- **Tools:** call them through `execute` on a machine, like any tool. Find one with `machine.tools.search({ query })`, check its inputs with `machine.tools.describe.tool({ path })`, then call `machine.tools.<server>.<tool>(args)`. The `execute` skill covers this.
- **Skills:** a plugin can ship its own skills, named `<plugin>:<skill>`, like `linear:linear`. Read one with the `skills` tool before you use that plugin's tools for real work.
- **Events:** to be woken when something happens in the service, see `codevisor-events`. If the user removes or turns off a plugin you subscribed to, a hidden `plugin.removed` or `plugin.disabled` event tells you which of your subscriptions it took with it.
- **Accounts:** a plugin can have several signed-in accounts, such as work and personal. `plugins.search` lists them. When there's more than one, its tools take an `account` argument (the account's label), and so does `events.subscribe`.
