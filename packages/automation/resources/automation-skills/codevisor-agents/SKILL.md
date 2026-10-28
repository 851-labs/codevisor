---
name: codevisor-agents
description: Start and coordinate other Codevisor coding agents as visible chats — beside you in your workspace, or in workspaces of their own. Use them instead of your harness's built-in subagents. Covers starting an agent in one call, following up, getting its final reply, answering its questions, finding your agents again, and closing or archiving them, plus debug tools for reading a transcript. Use whenever you want help with your task (research, reading code, a review, a small piece of the same change), another harness or model alongside you, separate pieces of work each with their own branch or PR, an agent per issue/PR/task, to orchestrate or supervise agents, review another agent's work, or clean up agent workspaces.
---

# Codevisor agents

Every Codevisor chat is an **agent**: a coding agent (Claude Code, Codex, …) running in a **workspace** of a **project**. Each one is visible to the user in the sidebar.

Never use your harness's built-in subagents (a Task or Agent tool, spawn_agent, and the like), even if your harness still offers them. The user can't see or steer them, they edit your checkout unnoticed, and they die on updates. Start a Codevisor agent instead, even for a quick question.

Everything goes through a machine handle. `machine.agents.<tool>(args)` is the same as `machine.tools.codevisor.agents.<tool>(args)`. Ids are passed and returned under the same name: `agentId`, `projectId`, `workspaceId`. Every list is `{ items, next? }`. Check exact inputs with `machine.tools.describe.tool({ path: "codevisor.agents.start" })`.

## Start an agent

```js
;async () => {
  const machine = machines.current
  const agent = await machine.agents.start({
    title: "Fix ABC-123: login redirect loop",
    prompt: "Fix ABC-123 … then open a PR.",
    isolation: "worktree",
    labels: { linear: "ABC-123", role: "worker" }
  })
  return agent
  // { agentId, title, projectId, workspaceId, worktreeName?, delivered, subscribed }
}
```

One call creates the checkout, the chat, and its first message, and subscribes you to its events.

`isolation` picks where it works:

- `"shared"`: your own workspace and checkout, as a tab beside you. Use it for quick, scoped help with your current task: research, reading code or docs, a review, a small piece of the same change, or a second opinion from another harness or model. Keep its task scoped so the two of you don't edit the same files at once, and close it with `agents.close` once you have its reply.
- `"worktree"`: a new git worktree in a new workspace, for separate work that ends in its own branch or PR.
- `"project"`: the project folder itself, in a new workspace, for separate work that needs no branch of its own, or a project that isn't a git repository.

```js
;async () =>
  machines.current.agents.start({
    title: "Find where sessions are archived",
    prompt: "List every code path that archives a session as file:line. Don't edit files.",
    isolation: "shared"
  })
```

Harness, model, reasoning, and project default to yours. Pass `harness` (an id from `machine.tools.codevisor.harnesses.list()`), `model`, or `project` (an id or name) to pick others. `labels` are free-form key/value pairs that help you find your agents again later.

## Get its final reply

Starting an agent subscribes you, so end your turn instead of waiting. When the agent finishes, its complete final reply arrives as a hidden message:

```
<codevisor-event type="session.turn_ended" agentId="…" title="Fix ABC-123: login redirect loop" stopReason="end_turn">
…the agent's complete final reply…
</codevisor-event>
```

- A turn that ends while the agent still runs background work (a background shell, a monitor) doesn't wake you right away. You hear once it stops with nothing left running, or after 3 minutes if it is still running then (a dev server, say).
- `session.waiting_for_user` carries a pending question, and `session.errored` carries the error.
- Several events from one agent while you're busy are combined, so you get its latest state once.
- The user never sees these events as messages they typed.

To check on an agent yourself:

```js
;async () => machines.current.agents.status({ agentId })
// { agentId, title, state: "working" | "waitingForUser" | "idle" | "errored", lastReply?, pendingQuestion? }
```

`lastReply` is the agent's complete last message. The reply is the interface: ask the agent for what you need in your prompt, and read it from the event or `status`.

## Follow up

```js
;async () =>
  machines.current.agents.message({ agentId, text: "Then add tests.", delivery: "queue" })
// { agentId, queueItemId?, delivered: "sent" | "steered" | "queued", steerDeclined? }
```

- An idle agent starts a turn with your message.
- While it is working, `delivery: "steer"` (the default) adds it to the running turn, so the agent reads it at its next step. Use that for corrections ("also cover the error path").
- `delivery: "queue"` waits until the turn finishes. Use that for the next, separate task.
- `steerDeclined: true` with `delivered: "queued"` means the turn couldn't take it, because its harness can't steer or is updating. If it can't wait, `agents.cancel({ agentId })` stops the turn.
- While Codevisor itself is updating, messages fail with an `updating` error. Chats the update paused continue on their own; send yours again once the update finishes.

## Answer its questions

When `state` is `waitingForUser`, read `pendingQuestion` and answer it:

```js
;async () => {
  const machine = machines.current
  const { pendingQuestion } = await machine.agents.status({ agentId })
  return machine.agents.answer({
    agentId,
    questionId: pendingQuestion.questionId,
    outcome: "answered",
    answers: { [pendingQuestion.questions[0].id]: { answers: ["Yes"] } }
  })
}
```

To give guidance instead of picking an answer, send it with `agents.message`.

## Find your agents again

```js
;async () => {
  const me = await machines.current.tools.codevisor.context.current()
  return machines.current.agents.list({ parentAgentId: me.agentId })
  // { items: [{ agentId, title, state, projectId, workspaceId, harness, labels, parentAgentId }], next? }
}
```

- Filter by `state`, `project`, `label` (`"linear=ABC-123"`, or just a key), or `parentAgentId`.
- Pass `next` back for the next page.
- Keep durable state in labels and parent links, not only in your context, so you can find your agents again after compaction or a restart.

## Other events and waiting

- `agents.subscribe({ agentId, events?, once? })` subscribes you to an agent you didn't start. `events` picks from `turn_ended`, `waiting_for_user`, `errored`, and `job_finished`.
- `agents.subscriptions()` and `agents.unsubscribe({ subscriptionId })` manage what you hold.
- `agents.wait({ agentIds, until?, timeoutMs? })` waits inside one execute call. It returns as soon as one of them reaches an `until` state (default `idle`, `waitingForUser`, `errored`).
  - `timeoutMs` shrinks to fit the execute call's budget, and `timedOut: true` is normal.
  - For anything longer than a minute or two, end your turn and let the event arrive.

## Review and clean up

- To review work, start another agent on the same project with `labels: { role: "reviewer", for: agentId }` and point it at the PR or branch.
- `agents.debug.branch_diff({ agentId })` gives a quick size of an agent's changes.
- When you're done with a shared helper (`"shared"`, in your own workspace), call `agents.close({ agentId })`. It stops if still running and you stop getting its events. Its tab leaves your workspace, its chat stays in history and `agents.list`, and your checkout is untouched.
- When you're done with a separate workspace (`"worktree"` or `"project"`), call `machine.tools.codevisor.workspaces.archive({ workspaceId })` with the `workspaceId` from `agents.start` or `agents.list`, once its work is merged or no longer needed.
  - It waits until the archive is done. It keeps a restorable snapshot of tracked and untracked files and deletes everything else in the checkout folder, ignored files included. Files already sent in a chat stay with that chat.
  - It releases the branch name, so push or open the PR first if the branch should stay.
- You can't close yourself or archive your own workspace.

## Debugging an agent

Talk to the agent first: ask it what happened, and read its reply. Only when that isn't enough, read its transcript:

```js
;async () => {
  const machine = machines.current
  const hits = await machine.agents.debug.search({
    agentId,
    query: "error",
    kinds: "tool",
    last: 5
  })
  // { items: [{ itemId, kind, tool?, at, snippet }], next? }
  return machine.agents.debug.item({ agentId, itemId: hits.items[0].itemId })
  // the whole item: a message's text, or a tool call's title, status, input, and output
}
```

- `search` filters by `query`, `kinds` (comma-separated `user`, `assistant`, `tool`, `event`), `tool` (part of a tool's title), and `last` (the number of hits). It returns the newest hits first.
- `agents.debug.transcript({ agentId, next? })` pages through the raw transcript.
- `agents.debug.queue({ agentId })` lists its queued messages. `queue_update`, `queue_reorder`, `queue_delete`, and `queue_send_now` manage them.
- `agents.debug.state({ agentId })` returns its full state.
- `agents.debug.update({ agentId, title?, labels? })` renames or relabels it.
- `config_set`, `mode_set`, `goal_set`, `goal_clear`, and `usage_limits` cover the rest.

## If an execute call returns a job handle

An execute call that outlives its `timeout_ms` returns `{ status: "running", jobId, … }` and keeps going. End your turn and wait for its `execution.job_finished` event, or check it with `machines.current.tools.codevisor.jobs.wait({ jobId })`.

## If you are the child

If `context.current()` has a `parentAgentId` and you are blocked, ask your parent directly:

```js
;async () => {
  const machine = machines.current
  const me = await machine.tools.codevisor.context.current()
  await machine.agents.message({
    agentId: me.parentAgentId,
    text: `Question from ${me.agentId}: …`
  })
}
```

## Agents on other machines

`(await machines.get("macbook")).agents.start({ …, project: "codevisor" })` starts an agent on that machine. Pass `project`, since that machine has its own projects; harness and model still default to yours. You aren't subscribed across machines, so check with that machine's `agents.status`. See `codevisor-machines`.
