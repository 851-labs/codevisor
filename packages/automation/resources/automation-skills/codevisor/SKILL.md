---
name: codevisor
description: Map of Codevisor's own tooling — other agents as visible chats, workspaces, other machines, and the Codevisor app. Use when work calls for a helper (research, reading code, a review), another harness or model alongside you, for separate pieces of work that each need their own workspace, branch, or PR (like an agent per issue), for orchestrating, checking on, answering, reviewing, or cleaning up other agents, for running tools on another of the user's machines, or for changing what the Codevisor app shows. Read this first, then the specific codevisor-* skill.
---

# Codevisor tooling

Everything Codevisor can do is reachable from its `execute` tool. Each call runs a short async JavaScript function in a sandbox and takes a `description`: a short present-tense label the user sees in the transcript ("Creating a workspace per Linear issue").

Every call goes through a machine handle: `const machine = machines.current` for the machine this chat runs on, or `await machines.get("macbook")` for another one.

```js
;async () => {
  const machine = machines.current
  const hits = await machine.tools.search({ query: "start agent" })
  return hits.items
}
```

`machine.tools.search` finds tools, skills, and sandbox globals. Use `machine.tools.describe.tool({ path })` for a tool's exact input schema before calling it. Call `status("…")` inside long scripts so the user can see progress.

## Choosing where work goes

- **Never your harness's built-in subagents** (a Task or Agent tool, spawn_agent, and the like), even if your harness still offers them. Start a Codevisor agent instead.
- **An agent in your workspace** (`isolation: "shared"`) fits quick, scoped help with your current task: research, reading code, a review, a small piece of the same change, or a second opinion from another harness or model. It shares your checkout and shows up as a tab beside you; close it with `agents.close` once you have its reply.
- **An agent in its own worktree** (`isolation: "worktree"`) fits separate pieces of work that each end in their own branch or PR, like one agent per issue. Each shows up in the user's sidebar, so they can follow it, jump in, and review its PR.

## What you can do

Read each skill named below by calling the `skills` tool with its name.

| Goal                                                                                                         | Skill                | Entry points                                                                                                                                             |
| ------------------------------------------------------------------------------------------------------------ | -------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Start other coding agents, follow up, get their final replies, answer their questions, close or archive them | `codevisor-agents`   | `machine.agents.start()`, `machine.agents.message()`, `machine.agents.status()`, `machine.agents.list()`                                                 |
| Run tools or agents on another of the user's machines                                                        | `codevisor-machines` | `machines.list()`, `machines.get(name).tools.*`, `machines.get(name).agents.*`                                                                           |
| See which Codevisor apps are open and what they show; open a chat, a page, or a layout for the user          | `codevisor-clients`  | `machine.clients.list()`, `client.navigate()`                                                                                                            |
| Know where you are                                                                                           | —                    | `machine.tools.codevisor.context.current()` gives your agentId, project, workspace, parentAgentId, machine, and the client that sent the current message |

## Composing these

These are building blocks; design the flow the user's task needs. Examples of what they combine into:

- An orchestrator reads a queue (Linear, GitHub, a file). For each item it starts a labeled agent in its own worktree, reads their final replies as they arrive, answers their questions, starts a reviewer agent on each finished branch, and archives their workspaces when they're done.
- A fan-out: one agent per package or test shard, with the results gathered from their final replies.
- Running the iOS simulator tools on the MacBook from a chat on the Mac Studio.

Keep durable state in Codevisor (agent labels and parent links), not only in your context, so you can find your agents again after compaction or a restart.
