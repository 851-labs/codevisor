---
name: codevisor
description: Use when work needs Codevisor's own tooling and you haven't yet picked the codevisor-* skill for it, such as a helper for research, reading code, or a review, another harness or model alongside you, an agent per issue or PR, supervising or cleaning up other agents, running tools on another of the user's machines, or changing what the Codevisor app shows.
---

# Codevisor tooling

Codevisor's own tools are globals in the `execute` tool, grouped by what they act on: `agents.start(args)`, `bots.list()`, `plugins.list()`, `sandboxes.list()`, `agents.archive(args)`, and so on. The `execute` skill covers how calls, `description`, and `status()` work.

- **Tools that act on one machine** (agents, workspaces, projects, bots, harnesses, terminals) take an optional `machine`: a machine id, a machine name, or a `Machine`. Leave it out to use the machine you run on. Results that name an agent include `machine`, the machine it runs on.
- **Tools shared by all your machines** (plugins, sandboxes, `machines.*`) take no `machine`.
- **Tools about this chat** (`context.current()`, `events.*`, `jobs.*`, `messages.*`) take no `machine`.
- **Machine objects** (`machines.current`, `await machines.get("macbook")`) run things on that machine itself: `machine.exec()`, `machine.readFile()`, `machine.clients.list()`, and plugin tools with `machine.tools.<server>.<tool>()`.

## Choosing where work goes

- **Never your harness's built-in subagents** (a Task or Agent tool, spawn_agent, and the like), even if your harness still offers them. Start a Codevisor agent instead.
- **`checkout: "shared"`** starts an agent in your own workspace and checkout, on your machine: quick, scoped help with your current task, like research, reading code, a review, a small piece of the same change, or a second opinion from another harness or model. It edits the same files you do and shows up as a tab beside you (as a split beside a bot's conversation, which has no tabs); archive it with `agent.archive()` once you have its reply.
- **`checkout: "worktree"`** starts an agent in a new git worktree, on any machine: separate work that ends in its own branch or PR, like one agent per issue. It shows in your agents pill, and the user opens it from there. Archive it with `agent.archive()` when the work is merged; that reclaims its worktree.
- **`checkout: "project"`** works in the project folder itself, without a new branch. **`checkout: "none"`** works in a fresh empty folder with no project.

## What you can do

Read each skill named below by calling the `skills` tool with its name.

| Goal                                                                                                        | Skill                | Entry points                                                                                              |
| ----------------------------------------------------------------------------------------------------------- | -------------------- | --------------------------------------------------------------------------------------------------------- |
| Start other coding agents, follow up, get their final replies, answer their questions, archive them         | `codevisor-agents`   | `agents.start()`, `agents.get()`, `agents.list()`, `agent.message()`, `agent.status()`, `agent.archive()` |
| List, create, change, archive, or delete bots                                                               | `codevisor-agents`   | `bots.*`                                                                                                  |
| Run commands, tools, or agents on another of the user's machines                                            | `codevisor-machines` | `machines.list()`, `machine.exec()`, `machine.tools.*`, `agents.start({ machine })`                       |
| Manage sandboxes: providers, profiles, and throwaway sandbox machines (start, follow, retry, destroy)       | `codevisor-machines` | `sandboxes.*`, `agents.start({ sandbox })`                                                                |
| See which Codevisor apps are open and what they show; open a chat, a page, a file, or a layout for the user | `codevisor-clients`  | `machine.clients.list()`, `client.navigate()`, `workspaces.pane_upsert()`                                 |
| Know where you are                                                                                          | —                    | `context.current()`                                                                                       |

`context.current()` returns `agentId`, `projectId`, `workspaceId`, `worktreeName` (absent in the project folder), `createdByAgentId` and `createdByAgentMachineId` (the agent that started you and its machine, if an agent did), `machine`, and `clientId` (the window that sent the current message, absent for automations and agent-sent messages).

## Composing these

These are building blocks; design the flow the user's task needs. For example:

- An orchestrator reads a queue (Linear, GitHub, a file). For each item it starts a labeled agent in its own worktree, on whichever machine fits, reads their final replies as they arrive, answers their questions, starts a reviewer agent on each finished branch, and archives their workspaces when they're done.
- A fan-out: one agent per package or test shard, spread over your machines, with the results gathered from their final replies.
- Running the iOS simulator tools on the MacBook from a chat on the Mac Studio.

## Common mistakes

- Using a built-in subagent because it starts faster. The user can't see or steer it; start a Codevisor agent.
- Keeping track of your agents only in your context. Keep durable state in Codevisor (agent labels, and the creator link `agents.list({ createdByAgentId })` reads) so you can find your agents again after compaction or a restart.
