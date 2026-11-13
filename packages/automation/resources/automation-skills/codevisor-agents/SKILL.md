---
name: codevisor-agents
description: Use when you want help with your task (research, reading code, a review, a small piece of the same change), another harness or model alongside you, separate pieces of work that each need their own branch or PR, an agent per issue, PR, or task, or when orchestrating, supervising, reviewing, answering, or cleaning up other agents. Also use it whenever you're tempted by a harness's built-in subagent (a Task or Agent tool, spawn_agent).
---

# Codevisor agents

Every Codevisor chat is an **agent**: a coding agent (Claude Code, Codex, …) running in a **workspace** of a **project**. Each one is visible to the user in the sidebar.

How much to hand off depends on what you are. A bot is an orchestrator: it hands nearly all real work to agents and stays free to talk with the user. A coding agent does its own task itself, and starts other agents only for help on the side, such as research or a review, or for separate pieces of work that each need their own branch.

Never use your harness's built-in subagents (a Task or Agent tool, spawn_agent, and the like), even if your harness still offers them. The user can't see or steer them, they edit your checkout unnoticed, and they die on updates. Start a Codevisor agent instead, even for a quick question.

Agent tools are the `agents` global: `agents.start(args)`, `agents.list(args)`, `agents.get(agentId)`. They run on the machine you run on unless you pass `machine` (a machine id, a machine name, or a `Machine`). `agents.start`, `agents.get`, and `agents.list` return **agent objects**: the agent's fields plus `machine`, the machine it runs on, and methods that already know both, so `agent.message("…")` reaches it on any machine. Ids are passed and returned under the same name: `agentId`, `projectId`, `workspaceId`. Every list is `{ items, next? }`. Check exact inputs with `machines.current.tools.describe.tool({ path: "agents.start" })`.

## Quick reference

| To                                | Call                                                                                                         |
| --------------------------------- | ------------------------------------------------------------------------------------------------------------ |
| Start an agent                    | `agents.start({ title, prompt, checkout, machine?, harness?, model?, project?, labels? })`, or `{ sandbox }` |
| Get one back from its id          | `agents.get(agentId)` finds it on any of your machines                                                       |
| Get its final reply               | End your turn; `session.turn_ended` brings it. Later: `agent.status()`                                       |
| Follow up                         | `agent.message({ text, delivery? })`, or `agent.message("…")`                                                |
| Answer its question               | `agent.answer({ questionId, outcome, answers })`                                                             |
| Stop its turn                     | `agent.cancel()`                                                                                             |
| Find your agents                  | `agents.list({ state?, project?, label?, createdByAgentId?, machine?, next? })`                              |
| Finish with any agent you started | `agent.archive()`                                                                                            |
| Hand one over to the user         | `agents.start({ …, standalone: true })`, or `agent.detach()` later                                           |

## Start an agent

```js
;async () => {
  const agent = await agents.start({
    title: "Fix ABC-123: login redirect loop",
    prompt: "Fix ABC-123 … then open a PR.",
    checkout: "worktree",
    labels: { linear: "ABC-123", role: "worker" }
  })
  return agent
  // { agentId, title, projectId, workspaceId, worktreeName?, delivered, subscribed, machine: { machineId, name } }
}
```

One call creates the checkout, the chat, and its first message. The new agent is linked to you as the agent that created it, on any machine: it shows in your agents pill, where the user opens it as a tab beside you, and its events reach you. It is not a sidebar item of its own unless you start it with `standalone: true`.

`checkout` says which files it works in:

- `"shared"`: your own workspace and checkout, as a tab beside you (a split beside a bot's conversation, which has no tabs), so it edits the same files you do. Use it for quick, scoped help with your current task: research, reading code or docs, a review, a small piece of the same change, or a second opinion from another harness or model. Keep its task scoped so the two of you don't edit the same files at once, and archive it with `agent.archive()` once you have its reply. It only works on your own machine.
- `"worktree"`: a new git worktree, for separate work that ends in its own branch or PR.
- `"project"`: the project folder itself, for separate work that needs no branch of its own, or a project that isn't a git repository.
- `"none"`: a fresh empty folder with no project, like a chat started with "No project" in the app. Nothing is added to the sidebar's projects, and it works on any machine, even one with no projects. Leave out `project`.

```js
;async () =>
  agents.start({
    title: "Find where sessions are archived",
    prompt: "List every code path that archives a session as file:line. Don't edit files.",
    checkout: "shared"
  })
```

Harness, model, reasoning, and project default to yours. Pass `harness` (an id from `harnesses.list()`), `model`, or `project` (an id or name) to pick others. `labels` are free-form key/value pairs that help you find your agents again later. Pass `machine` to run it on another of the user's machines; see "Agents on other machines" below.

```js
;async () =>
  agents.start({
    title: "Check the Xcode version",
    prompt: "Run xcodebuild -version and reply with its output.",
    checkout: "none",
    machine: "macbook"
  })
```

To run it on a new sandbox, pass `sandbox` (a profile id or name from `sandboxes.profiles_list()`) and leave out `checkout` and `machine`: the agent works in a fresh clone of the project on the sandbox. The call returns at once with `{ sandboxId, state: "creating" }`. A few minutes later the agent starts and you get its events as usual. `sandboxes.wait({ sandboxId })` returns once the sandbox is ready, with `agentId` and `machineId`, so `agents.get({ agentId, machine: machineId })` reaches it. If setup fails the sandbox shows `state: "failed"` with `error`: read `sandboxes.log({ sandboxId })` and call `sandboxes.retry({ sandboxId })`. See `codevisor-machines` for sandboxes.

## Write its prompt

The prompt is the agent's whole brief. Write it the way you'd hand work to a capable coworker: the agent can read the code, plan, and work out the steps itself. What it can't do is read your conversation.

- **Pass the request on with its reasons.** When the work comes from someone you're talking with, pass their request on nearly word for word, including why they want it. The reasons let the agent make the same judgment calls they would.
- **Write it as your own request.** Don't mention the person behind it or yourself as a go-between: no "the user wants", "they said", or names. Write "Change x so y happens instead.", not "The user doesn't like x, so they want y."
- **Keep an open question open.** If they're asking for options, ask the agent for options. Don't turn it into an instruction they never gave.
- **Add only what it can't know:** context from earlier in your conversation, decisions already made, written as plain requirements such as "Keep the CSV header byte-for-byte.", how to verify the work when that isn't obvious, and where to stop, such as "Open a PR, but don't merge it." or "Commit, but don't push."
- **Don't write a plan for it.** Leave out step-by-step instructions unless the steps themselves are the requirement.

For example, when the user writes "I don't like how the sidebar collapses on small windows, it hides the unread badge. what else could we do?", a good brief is "I don't like how the sidebar collapses on small windows, because it hides the unread badge. What are some other options? Reply with a few and your recommendation; don't change code yet." A poor one is "The user wants the sidebar changed to an overlay. 1. Open Sidebar.swift. 2. …": it drops the reason, answers the question for them, and names the user.

Your own coordination concerns, such as machine load, disk space, scheduling, or other agents' work, belong in the prompt only when they change how the task is done. Give one complete brief up front, then follow up only when something changes.

## Get its final reply

Starting an agent links it to you, so end your turn instead of waiting. When the agent finishes, its complete final reply arrives as a hidden message:

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
;async () => (await agents.get(agentId)).status()
// { agentId, title, state: "working" | "waitingForUser" | "idle" | "errored", lastReply?, pendingQuestion? }
```

`lastReply` is the agent's complete last message. The reply is the interface: ask the agent for what you need in your prompt, and read it from the event or `status`.

## Follow up

```js
;async () => (await agents.get(agentId)).message({ text: "Then add tests.", delivery: "queue" })
// { agentId, queueItemId?, delivered: "sent" | "steered" | "queued", steerDeclined? }
```

Pick how to follow up by how the new request relates to the work under way:

- **It changes the work** ("also cover the error path", "do it this way instead"): steer, the default. The agent folds it in now instead of finishing the old version first.
- **It replaces the work** ("never mind, do x instead") and x doesn't build on what the agent has done: stop the agent with `agent.cancel()`, archive it, and start a new agent with a fresh brief. Archiving deletes uncommitted work, so ask first if it's unclear whether the work so far is still wanted.
- **It builds on the result** ("then add tests for it"): queue it, so it starts once the current turn ends.

How delivery works:

- An idle agent starts a turn with your message.
- While it is working, `delivery: "steer"` (the default) adds it to the running turn, so the agent reads it at its next step.
- `delivery: "queue"` waits until the turn finishes. Queued messages go in the order you sent them, each once.
- A steer never overtakes messages you queued earlier: they go into the running turn first, in order, then the steer.
- `steerDeclined: true` with `delivered: "queued"` means the turn couldn't take it, because its harness can't steer or is updating. If it can't wait, `agent.cancel()` stops the turn.
- While Codevisor itself is updating, messages fail with an `updating` error. Chats the update paused continue on their own; send yours again once the update finishes.

## Answer its questions

A `session.waiting_for_user` event brings an agent's question. `agent.status()` shows it too, as `pendingQuestion` while `state` is `waitingForUser`. The agent stays paused until the question is answered. First decide who answers it:

- **Answer it yourself** when the answer is already settled: the user stated it, it was decided earlier in your conversation, it follows from the task's requirements, or it's a low-stakes implementation detail within the task.
- **Ask the user** when the answer depends on the user's preferences or intent and nothing has settled it yet. The agent's recommendation helps the user choose. It doesn't settle the question.
- **Bring a discovery to the user:** something the agent found that the user doesn't know about and would care about, such as "doing X breaks Y". If you already discussed it with the user, answer it from what they decided. Otherwise ask them, and explain plainly what the agent found and what it means before you give the options.

To answer it yourself:

```js
;async () => {
  const agent = await agents.get(agentId)
  const { pendingQuestion } = await agent.status()
  return agent.answer({
    questionId: pendingQuestion.questionId,
    outcome: "answered",
    answers: { [pendingQuestion.questions[0].id]: { answers: ["Yes"] } }
  })
}
```

To give guidance instead of picking an answer, send it with `agent.message`.

To ask the user, use your harness's own tool for asking the user questions. Ask the same question, reworded for the user if needed, with the same options, and mark which one the agent recommends. Then relay their choice with `agent.answer`, using the agent's option label. If you are a bot, ask in a message with `messages.send` instead, and relay their reply the same way.

One `agent.answer` call answers every question in the prompt, so it can't answer some now and the rest later. When a prompt mixes settled questions with open ones, ask the user all the open ones together, then send every answer in one call. The agent stays paused while the user decides. Carry on with your other work in the meantime.

Examples:

- **Answer it yourself.** The user asked for the fix on the `release-2.4` branch. The agent asks whether to open its PR against `main` or `release-2.4`. Answer `release-2.4`.
- **Ask the user.** The user asked for an export button. The agent asks whether it should export CSV or JSON, and recommends CSV. Nothing settled the format, so ask the user that question with both options, mark CSV as the agent's recommendation, and relay their choice.
- **Discovery.** The user asked to raise the webhook retry limit to 10. The agent found that the payment webhook doesn't check for repeats, so every retry can charge the customer again, and it asks whether to add an idempotency key first. Tell the user what that means, such as "With 10 retries, one failed payment webhook can charge a customer up to 10 times. The agent suggests adding an idempotency key first.", then ask. If you had already talked through double charges with the user, answer from what they decided.

## Find your agents again

```js
;async () => {
  const me = await context.current()
  return agents.list({ createdByAgentId: me.agentId })
  // { items: [agent, …], next? }, each an agent object with createdByAgentId and createdByAgentMachineId
}
```

- Filter by `state`, `project`, `label` (`"linear=ABC-123"`, or just a key), or `createdByAgentId`.
- `agents.list` lists one machine: yours, or the one you pass as `machine`. To gather agents you started everywhere, list each of `(await machines.list()).items` with `machine`.
- Pass `next` back for the next page.
- Keep durable state in labels and the creator link, not only in your context, so you can find your agents again after compaction or a restart.

## Other events and waiting

- `agents.subscribe({ agentId, events?, once? })` subscribes you to an agent on your machine that you didn't start. `events` picks from `turn_ended`, `waiting_for_user`, `errored`, and `job_finished`.
- `agents.subscriptions()` and `agents.unsubscribe({ subscriptionId })` manage what you hold.
- `agent.wait({ until?, timeoutMs? })`, or `agents.wait({ agentIds, until?, timeoutMs?, machine? })` for several on one machine, waits inside one execute call. It returns as soon as one of them reaches an `until` state (default `idle`, `waitingForUser`, `errored`). `timeoutMs` shrinks to fit the execute call's budget, and `timedOut: true` is normal. Use it only for waits of a minute or two; for anything longer, end your turn and let the event arrive.

## Review and clean up

- To review work, start another agent on the same project with `labels: { role: "reviewer", for: agentId }` and point it at the PR or branch.
- `agent.debug.branch_diff()` gives a quick size of an agent's changes.
- When you're done with an agent you started, call `agent.archive()`: once you have a shared helper's reply, or once a separate agent's work is merged or no longer needed. It stops if still running, you stop getting its events, and its chat is archived: it takes no more messages and its tab closes.
  - Cleanup depends on where it ran. A `"shared"` helper ran in your checkout, so nothing on disk changes. A `"worktree"` agent's worktree is reclaimed when nothing else uses it: tracked and untracked files are kept as a restorable snapshot and everything else in the folder, ignored files included, is deleted. The project folder itself is never touched. Files already sent in a chat stay with that chat.
  - It releases the branch name, so push or open the PR first if the branch should stay.
- You can't archive yourself.

## Agents that stand alone

By default an agent you start is yours: it sits in your agents pill, and it is archived when you are. That fits work that is a step in your own task.

Some work is the user's to follow on its own, like one agent per ticket started by a bot. Start it with `standalone: true`, or call `agent.detach()` on an agent you already started.

- It gets its own item in the user's sidebar and stays out of your pill.
- It is not archived when you are.
- You can still message it, get its events, and archive it.
- `standalone` needs a workspace of its own, so it does not go with `checkout: "shared"`. Detaching a shared helper moves it into its own workspace on the same checkout.
- Detaching can't be undone.

## Debugging an agent

Talk to the agent first: ask it what happened, and read its reply. Only when that isn't enough, read its transcript:

```js
;async () => {
  const agent = await agents.get(agentId)
  const hits = await agent.debug.search({ query: "error", kinds: "tool", last: 5 })
  // { items: [{ itemId, kind, tool?, at, snippet }], next? }
  return agent.debug.item({ itemId: hits.items[0].itemId })
  // the whole item: a message's text, or a tool call's title, status, input, and output
}
```

- `search` filters by `query`, `kinds` (comma-separated `user`, `assistant`, `tool`, `event`), `tool` (part of a tool's title), and `last` (the number of hits). It returns the newest hits first.
- `agent.debug.transcript({ next? })` pages through the raw transcript.
- `agent.debug.queue()` lists its queued messages. `queue_update`, `queue_reorder`, `queue_delete`, and `queue_send_now` manage them.
- `agent.debug.state()` returns its full state, and `agent.debug.update({ title?, labels? })` renames or relabels it.
- `config_set`, `mode_set`, `goal_set`, `goal_clear`, and `usage_limits` cover the rest.

## If you are the child

If `context.current()` has a `createdByAgentId` and you are blocked, ask the agent that started you directly, on its machine:

```js
;async () => {
  const me = await context.current()
  await agents.message({
    agentId: me.createdByAgentId,
    machine: me.createdByAgentMachineId,
    text: `Question from ${me.agentId}: …`
  })
}
```

## Agents on other machines

`agents.start({ …, checkout: "worktree", machine: "macbook", project: "codevisor" })` starts an agent on that machine. Pass `project` when you aren't in a project with a git remote, since that machine has its own projects, or `checkout: "none"` for a throwaway chat in a fresh empty folder there; harness and model still default to yours. Nothing else changes: it is linked to you, it shows under you in the sidebar, its events reach you on your machine, and its agent object reaches it there. `checkout: "shared"` only works on your own machine. See `codevisor-machines`.

## Common mistakes

- Blocking on `agent.wait()` or polling `agent.status()` for a long task. End your turn; the event carries the final reply.
- Answering a question the user hasn't settled with your own guess or the agent's recommendation. Ask the user.
- Answering a discovery without telling the user what the agent found.
- Breaking a request into step-by-step instructions, or passing on what to do without why.
- Naming the user in a prompt ("the user wants", "they said"). Write it as your own request.
- Pasting your whole conversation into a prompt instead of the request and the context it needs.
- Queueing a change to work that's under way. Steer it, or replace the agent if the work is no longer wanted.
- Leaving agents you started unarchived after their work is done.
- Archiving before the branch is pushed. Archiving releases the branch name.
