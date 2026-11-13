---
name: codevisor-bots
description: Use when the user asks you to list, create, rename, change, fork, archive, restore, or delete a Codevisor bot, or to add or remove a project on one, and when you need to message a bot. A bot is the user's long-lived assistant in Bots mode, not an agent you start for a task.
---

# Codevisor bots

A **bot** is a Codevisor chat with its own folder and read-only checkouts of one or more projects. It shows in the sidebar's Bots mode.

| To                                    | Call                                                                                    |
| ------------------------------------- | --------------------------------------------------------------------------------------- |
| List bots, archived ones included     | `bots.list()`                                                                           |
| Read one                              | `bots.get({ botId })`                                                                   |
| Create one                            | `bots.create({ name, harnessId, projectIds, configSelections?, mascot? })`              |
| Rename it, or change mascot or model  | `bots.update({ botId, name?, mascot?, configSelections? })`                             |
| Fork it onto another harness or model | `bots.fork({ botId, harnessId, configSelections?, name?, moveAgents? })`                |
| Archive or restore it                 | `bots.update({ botId, isArchived: true })` or `isArchived: false`                       |
| Add or remove a project               | `bots.projects_add({ botId, projectId })`, `bots.projects_remove({ botId, projectId })` |
| Delete it                             | `bots.delete({ botId, confirm: true })`                                                 |
| Message it                            | `bots.message({ botId, text, machine? })`                                               |
| Read your thread with it              | `bots.messages({ botId, machine?, limit?, before? })`                                   |

```js
;async () => {
  const { items } = await projects.list()
  const project = items.find((p) => p.name === "web")
  return bots.create({
    name: "Release Notes",
    harnessId: "codex",
    projectIds: [project.projectId],
    configSelections: { model: "gpt-6" }
  })
}
```

- A bot runs on one machine. Create it there with that machine's `projectIds`: `bots.create({ …, machine: "studio" })`, after `projects.list({ machine: "studio" })`.
- `harnessId` is an id from `harnesses.list()` and can't change later.
- `configSelections` sets the bot chat's options, such as `{ model }`. `server.capabilities({ harnessId })` lists each option's `id` and values. Leave it out for the harness defaults. `bots.get` and `bots.list` return the bot's current `configSelections`.
- `bots.fork` makes a new bot on the same machine and projects, with the old bot's mascot, notes and conversation. It moves the old bot's agents to the fork unless you pass `moveAgents: false`. Use it when the user wants to keep working with a bot on a different harness or model.
- `mascot` is the bot's avatar: `{ color, hat, hatColor?, eyewear, eyewearColor? }`, with the choices listed in the tool's input schema. `hatColor` and `eyewearColor` only apply to items that offer colors and default to `auto`. A new bot gets the next color in turn and no hat or eyewear.

## Messaging a bot

`bots.message({ botId, text })` writes to a bot from you, whether you are another bot or an agent. You and that bot share one thread, which the user is not part of. The bot's reply reaches you as a `<codevisor-event type="thread.message" threadId="…">`, and `bots.messages({ botId })` reads the thread back.

- It works across machines. For a bot on another machine pass `machine`, the same as for the other `bots` tools: `bots.message({ botId, text, machine })`. A reply's event carries the bot's `machineId`, which you can pass as `machine`.
- `agents.message` refuses a bot. A bot is not an agent.
- A bot refuses `bots.message` from an agent it started. It already gets that agent's final reply when the turn ends, so put what it needs there.
- Write when you have something the bot needs or a question for it. Don't write only to acknowledge.

A bot is always the user's. No agent owns one, so the agent tools don't act on bots: archiving, detaching, cancelling, answering its questions, renaming, and changing its mode, goal, model or queue through `agents` are all refused. Use `bots.update` and `bots.delete`, and only when the user asks.
