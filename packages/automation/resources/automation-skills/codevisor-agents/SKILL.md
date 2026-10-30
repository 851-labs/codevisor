---
name: codevisor-agents
description: Use when you want help with your task (research, reading code, a review, a small piece of the same change), another harness or model alongside you, separate pieces of work that each need their own branch or PR, an agent per issue, PR, or task, or when orchestrating, supervising, reviewing, answering, or cleaning up other agents. Also use it whenever you're tempted by a harness's built-in subagent (a Task or Agent tool, spawn_agent).
---

# Codevisor agents

Every Codevisor chat is an **agent**: a coding agent (Claude Code, Codex, …) running in a **workspace** of a **project**. Each one is visible to the user in the sidebar.

Never use your harness's built-in subagents (a Task or Agent tool, spawn_agent, and the like), even if your harness still offers them. The user can't see or steer them, they edit your checkout unnoticed, and they die on updates. Start a Codevisor agent instead, even for a quick question.

Everything goes through a machine handle. `machine.agents.<tool>(args)` is the same as `machine.tools.codevisor.agents.<tool>(args)`. Ids are passed and returned under the same name: `agentId`, `projectId`, `workspaceId`. Every list is `{ items, next? }`. Check exact inputs with `machine.tools.describe.tool({ path: "codevisor.agents.start" })`.

## Quick reference

| To                                           | Call                                                                                                           |
| -------------------------------------------- | -------------------------------------------------------------------------------------------------------------- |
| Start an agent                               | `agents.start({ title, prompt, isolation, harness?, model?, project?, noProject?, labels?, sandboxProfile? })` |
| Get its final reply                          | End your turn; `session.turn_ended` brings it. Later: `agents.status({ agentId })`                             |
| Follow up                                    | `agents.message({ agentId, text, delivery? })`                                                                 |
| Answer its question                          | `agents.answer({ agentId, questionId, outcome, answers })`                                                     |
| Stop its turn                                | `agents.cancel({ agentId })`                                                                                   |
| Find your agents                             | `agents.list({ state?, project?, label?, parentAgentId?, next? })`                                             |
| Finish with a `"shared"` helper              | `agents.close({ agentId })`                                                                                    |
| Finish with a `"worktree"`/`"project"` agent | `machine.tools.codevisor.workspaces.archive({ workspaceId })`                                                  |

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

For a throwaway chat that needs no project, pass `noProject: true` instead of `project`. The agent works in a fresh empty folder on that machine, like a chat started with "No project" in the app: nothing is added to the sidebar's projects, and `isolation` is ignored. It works on any machine, even one with no projects. Archive its workspace when you're done, as for `"project"`.

```js
;async () =>
  (await machines.get("macbook")).agents.start({
    title: "Check the Xcode version",
    prompt: "Run xcodebuild -version and reply with its output.",
    isolation: "project",
    noProject: true
  })
```

To run it on a new sandbox, pass `sandboxProfile` (a profile id or name from `machine.tools.codevisor.sandboxes.profiles_list()`). The call returns at once with `{ sandboxId, state: "creating" }`; `isolation` is ignored because the agent works in a fresh clone of the project on the sandbox. A few minutes later the agent starts and you're subscribed to it as usual. `machine.tools.codevisor.sandboxes.wait({ sandboxId })` returns once the sandbox is ready, with `agentId` and `machineId`, so `(await machines.get(machineId)).agents.status({ agentId })` reaches it. If setup fails the sandbox shows `state: "failed"` with `error`: read `sandboxes.log({ sandboxId })` and call `sandboxes.retry({ sandboxId })`. See `codevisor-machines` for sandboxes.

## Write its prompt

The prompt is the agent's whole brief. Write it as concise, direct instructions about the work:

- **Goal:** what to change, build, or find out.
- **Requirements and constraints:** what must be true when it's done. Write each decision as a plain requirement, such as "Keep the CSV header byte-for-byte.", rather than as who said or approved it.
- **Verification:** how to check the work, such as which tests to run or what behavior to confirm.
- **Stopping point:** what to hand back, and what to hold for you, such as "Commit, but don't push."

Your own coordination concerns, such as machine load, disk space, scheduling, or other agents' work, belong in the prompt only when they change how the task is done. Give one complete brief up front, then steer with `agents.message` only when something changes.

## Get its final reply

Starting an agent subscribes you, so end your turn instead of waiting. When the agent finishes, its complete final reply arrives as a hidden message:

```
<codevisor-event type="session.turn_ended" agentId="…" title="Fix ABC-123: login redirect loop" stopReason="end_turn">
…the agent's complete final reply…
</codevisor-event>
```

- You hear as soon as its turn is done, the same moment the user would see it as finished. Background work it leaves running, such as a dev server or a monitor, doesn't hold the event back. If that work later wakes the agent, its new turn sends a new event.
- Only a turn still waiting on its own sub-agents, an active goal, or messages queued to it isn't done yet.
- `session.waiting_for_user` carries a pending question, and `session.errored` carries the error.
- Events that arrive while you're busy wait for your turn to end, then arrive together in the order they happened. None are dropped.
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
- `delivery: "queue"` waits until the turn finishes. Use that for the next, separate task. Queued messages go in the order you sent them, each once.
- A steer never overtakes messages you queued earlier: they go into the running turn first, in order, then the steer.
- `steerDeclined: true` with `delivered: "queued"` means the turn couldn't take it, because its harness can't steer or is updating. If it can't wait, `agents.cancel({ agentId })` stops the turn.
- While Codevisor itself is updating, messages fail with an `updating` error. Chats the update paused continue on their own; send yours again once the update finishes.

## Answer its questions

A `session.waiting_for_user` event brings an agent's question. `agents.status` shows it too, as `pendingQuestion` while `state` is `waitingForUser`. The agent stays paused until the question is answered. First decide who answers it:

- **Answer it yourself** when the answer is already settled: the user stated it, it was decided earlier in your conversation, it follows from the task's requirements, or it's a low-stakes implementation detail within the task.
- **Ask the user** when the answer depends on the user's preferences or intent and nothing has settled it yet. The agent's recommendation helps the user choose. It doesn't settle the question.
- **Bring a discovery to the user:** something the agent found that the user doesn't know about and would care about, such as "doing X breaks Y". If you already discussed it with the user, answer it from what they decided. Otherwise ask them, and explain plainly what the agent found and what it means before you give the options.

To answer it yourself:

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

To ask the user, use your harness's own tool for asking the user questions. Ask the same question, reworded for the user if needed, with the same options, and mark which one the agent recommends. Then relay their choice with `agents.answer`, using the agent's option label. If you are a bot, ask in a message with `messages.send` instead, and relay their reply the same way.

One `agents.answer` call answers every question in the prompt, so it can't answer some now and the rest later. When a prompt mixes settled questions with open ones, ask the user all the open ones together, then send every answer in one call. The agent stays paused while the user decides. Carry on with your other work in the meantime.

Examples:

- **Answer it yourself.** The user asked for the fix on the `release-2.4` branch. The agent asks whether to open its PR against `main` or `release-2.4`. Answer `release-2.4`.
- **Ask the user.** The user asked for an export button. The agent asks whether it should export CSV or JSON, and recommends CSV. Nothing settled the format, so ask the user that question with both options, mark CSV as the agent's recommendation, and relay their choice.
- **Discovery.** The user asked to raise the webhook retry limit to 10. The agent found that the payment webhook doesn't check for repeats, so every retry can charge the customer again, and it asks whether to add an idempotency key first. Tell the user what that means, such as "With 10 retries, one failed payment webhook can charge a customer up to 10 times. The agent suggests adding an idempotency key first.", then ask. If you had already talked through double charges with the user, answer from what they decided.

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
- `agents.wait({ agentIds, until?, timeoutMs? })` waits inside one execute call. It returns as soon as one of them reaches an `until` state (default `idle`, `waitingForUser`, `errored`). `timeoutMs` shrinks to fit the execute call's budget, and `timedOut: true` is normal. Use it only for waits of a minute or two; for anything longer, end your turn and let the event arrive.

## Review and clean up

- To review work, start another agent on the same project with `labels: { role: "reviewer", for: agentId }` and point it at the PR or branch.
- `agents.debug.branch_diff({ agentId })` gives a quick size of an agent's changes.
- When you're done with a shared helper (`"shared"`, in your own workspace), call `agents.close({ agentId })`. It stops if still running and you stop getting its events. Its tab leaves your workspace, its chat stays in history and `agents.list`, and your checkout is untouched.
- When you're done with a separate workspace (`"worktree"` or `"project"`), call `machine.tools.codevisor.workspaces.archive({ workspaceId })` with the `workspaceId` from `agents.start` or `agents.list`, once its work is merged or no longer needed.
  - It waits until the archive is done, and its chats stop. It keeps a restorable snapshot of tracked and untracked files and deletes everything else in the checkout folder, ignored files included. Files already sent in a chat stay with that chat.
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
- `agents.debug.state({ agentId })` returns its full state, and `agents.debug.update({ agentId, title?, labels? })` renames or relabels it.
- `config_set`, `mode_set`, `goal_set`, `goal_clear`, and `usage_limits` cover the rest.

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

`(await machines.get("macbook")).agents.start({ …, project: "codevisor" })` starts an agent on that machine. Pass `project`, since that machine has its own projects, or `noProject: true` for a throwaway chat in a fresh empty folder there; harness and model still default to yours. You aren't subscribed across machines, so check with that machine's `agents.status`. See `codevisor-machines`.

## Common mistakes

- Blocking on `agents.wait` or polling `agents.status` for a long task. End your turn; the event carries the final reply.
- Answering a question the user hasn't settled with your own guess or the agent's recommendation. Ask the user.
- Answering a discovery without telling the user what the agent found.
- Writing a prompt that retells your conversation instead of stating the task and its requirements.
- Leaving shared helpers open or worktree workspaces unarchived after their work is done.
- Archiving before the branch is pushed. Archiving releases the branch name.
