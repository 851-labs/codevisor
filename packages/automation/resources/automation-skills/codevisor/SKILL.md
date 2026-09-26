---
name: codevisor
description: Map of Codevisor's own tooling — other agents as visible chats, workspaces, other machines, and the Codevisor app. Use when work calls for another harness or model alongside you, for separate pieces of work that each need their own workspace, branch, or PR (like an agent per issue), for orchestrating, checking on, answering, reviewing, or cleaning up other agents, for running tools on another of the user's machines, or for changing what the Codevisor app shows. Read this first, then the specific codevisor-* skill.
---

# Codevisor tooling

Everything Codevisor can do is reachable from its `execute` tool. Each call runs a short async JavaScript function in a sandbox and takes a `description`: a short present-tense label the user sees in the transcript ("Creating a workspace per Linear issue").

```js
;async () => {
  const hits = await tools.search({ query: "create session" })
  return hits.items.map((item) => item.path)
}
```

Use `tools.search` to find a tool and `tools.describe.tool({ path })` for its exact input schema before calling it. Call `status("…")` inside long scripts so the user can see progress.

## Choosing where work goes

- **Built-in subagents** usually fit help with your current task: exploring the code, research, a quick review, small edits. Nothing is left behind for the user to manage.
- **A new chat in the current workspace** fits another agent working on the same change beside you, such as a different harness or model for a second opinion or to implement a piece, or a conversation the user may want to follow. It shares your checkout.
- **A new workspace with its own worktree** fits separate pieces of work that each end in their own branch or PR, like one agent per issue. Each shows up in the user's sidebar, so they can follow it, jump in, and review its PR.

## What you can do

| Goal                                                                                                                                          | Skill                | Entry points                                                                                                                           |
| --------------------------------------------------------------------------------------------------------------------------------------------- | -------------------- | -------------------------------------------------------------------------------------------------------------------------------------- |
| Start other coding agents, each in its own workspace; prompt them, wait on them, read their transcripts, answer their questions, archive them | `codevisor-agents`   | `tools.codevisor.sessions.*`, `tools.codevisor.workspaces.*`                                                                           |
| Run tools or agents on another of the user's machines                                                                                         | `codevisor-machines` | `machines.list()`, `machines.get(name).tools.*`                                                                                        |
| See which Codevisor apps are open and what they show; open a chat, a page, or a layout for the user                                           | `codevisor-clients`  | `clients.list()`, `client.navigate()`                                                                                                  |
| Know where you are                                                                                                                            | —                    | `tools.codevisor.context.current()` gives your session, project, parent session, machine, and the client that sent the current message |

## Composing these

These are building blocks; design the flow the user's task needs. Examples of what they combine into:

- An orchestrator reads a queue (Linear, GitHub, a file). For each item it creates a labeled agent in its own workspace, waits for the agents, answers their questions, starts a reviewer agent on each finished branch, and archives workspaces when they're done.
- A fan-out: one agent per package or test shard, with the results gathered from their transcripts.
- Running the iOS simulator tools on the MacBook from a chat on the Mac Studio.

Keep durable state in Codevisor (session labels and parent links), not only in your context, so you can rediscover your agents after compaction or a restart.
