---
name: codevisor
description: Use when work needs Codevisor's own tooling and you haven't yet picked the codevisor-* skill for it, such as a helper for research, reading code, or a review, another harness or model alongside you, an agent per issue or PR, supervising or cleaning up other agents, running tools on another of the user's machines, or changing what the Codevisor app shows.
---

# Codevisor tooling

Everything Codevisor can do is reachable from its `execute` tool, through a machine handle: `machines.current` for the machine this chat runs on, or `await machines.get("macbook")` for another one. The `execute` skill covers how calls, `description`, and `status()` work.

## Choosing where work goes

- **Never your harness's built-in subagents** (a Task or Agent tool, spawn_agent, and the like), even if your harness still offers them. Start a Codevisor agent instead.
- **An agent in your workspace** (`isolation: "shared"`) fits quick, scoped help with your current task: research, reading code, a review, a small piece of the same change, or a second opinion from another harness or model. It shares your checkout and shows up as a tab beside you; close it with `agents.close` once you have its reply.
- **An agent in its own worktree** (`isolation: "worktree"`) fits separate pieces of work that each end in their own branch or PR, like one agent per issue. Each shows up in the user's sidebar, so they can follow it, jump in, and review its PR. Archive its workspace with `workspaces.archive` when the work is merged.

## What you can do

Read each skill named below by calling the `skills` tool with its name. `machine` is `machines.current` or `await machines.get(name)`.

| Goal                                                                                                         | Skill                | Entry points                                                                                                                                                                       |
| ------------------------------------------------------------------------------------------------------------ | -------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Start other coding agents, follow up, get their final replies, answer their questions, close or archive them | `codevisor-agents`   | `machine.agents.start()`, `machine.agents.message()`, `machine.agents.status()`, `machine.agents.list()`, `machine.agents.close()`, `machine.tools.codevisor.workspaces.archive()` |
| Run tools or agents on another of the user's machines                                                        | `codevisor-machines` | `machines.list()`, `(await machines.get(name)).tools.*`, `(await machines.get(name)).agents.*`                                                                                     |
| Manage sandboxes: providers, profiles, and throwaway sandbox machines (start, follow, retry, destroy)        | `codevisor-machines` | `machine.tools.codevisor.sandboxes.*`, `machine.agents.start({ sandboxProfile })`                                                                                                  |
| See which Codevisor apps are open and what they show; open a chat, a page, a file, or a layout for the user  | `codevisor-clients`  | `machine.clients.list()`, `client.navigate()`, `machine.tools.codevisor.workspaces.pane_upsert()`                                                                                  |
| Know where you are                                                                                           | —                    | `machine.tools.codevisor.context.current()`                                                                                                                                        |

`context.current()` returns `agentId`, `projectId`, `workspaceId`, `worktreeName` (absent in the project folder), `parentAgentId` (the agent that started you, if any), `machine`, and `clientId` (the window that sent the current message, absent for automations and agent-sent messages).

## Composing these

These are building blocks; design the flow the user's task needs. For example:

- An orchestrator reads a queue (Linear, GitHub, a file). For each item it starts a labeled agent in its own worktree, reads their final replies as they arrive, answers their questions, starts a reviewer agent on each finished branch, and archives their workspaces when they're done.
- A fan-out: one agent per package or test shard, with the results gathered from their final replies.
- Running the iOS simulator tools on the MacBook from a chat on the Mac Studio.

## Common mistakes

- Using a built-in subagent because it starts faster. The user can't see or steer it; start a Codevisor agent.
- Keeping track of your agents only in your context. Keep durable state in Codevisor (agent labels and parent links) so you can find your agents again after compaction or a restart.
