---
name: codevisor-agents
description: Create and coordinate other Codevisor coding agents as visible chats — your own subagents beside you or with their own worktree, or independent agents the user manages. Covers starting sessions, sending prompts, waiting for them to finish or ask something, reading transcripts, answering questions, labeling, and archiving. Use when you want another harness or model working alongside you on the same change, separate pieces of work each with their own branch or PR, an agent per issue/PR/task, orchestrate or supervise agents, review another agent's work, or clean up agent workspaces.
---

# Codevisor agents

Every Codevisor chat is a **session**: a coding agent (Claude Code, Codex, …) running in a **workspace** of a **project**. You can create sessions, talk to them, and watch them. Each one is visible to the user: your subagents appear in your tab bar, independent agents get their own sidebar row.

Paths below are under `tools.codevisor.*`. Ids are passed by name: `sessionId`, `workspaceId`, `projectId` (never a bare `id`). Check exact inputs with `tools.describe.tool({ path: "codevisor.sessions.create" })`.

## Where am I

```js
;async () => tools.codevisor.context.current()
// { sessionId, projectId, workspaceId, worktreeName?, parentSessionId?, machine: { id, name }, clientId? }
```

## Pick a placement

Every agent you create is either **your subagent** (you own it, you supervise it, and the user mostly ignores it) or an **independent agent** (a line of work the user manages themselves). `sessions.create` takes `workspacePlacement`:

| Placement          | Use it for                                                                                                                   | What the user sees                                                  |
| ------------------ | ---------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------- |
| `shared` (default) | Research, review, a second opinion, a scoped piece of the same change: anything that won't fight your edits in one checkout. | A tab beside your chat.                                             |
| `owned`            | Parallel code changes that would collide in one checkout (pass `worktreeName` for its own worktree).                         | A tab group in your tab bar. It is archived with you.               |
| `independent`      | Only when the user asks for a separate line of work they will manage themselves.                                             | A top-level sidebar row of its own, like any chat the user started. |

When unsure, use `shared`. Never pick `independent` just to keep things tidy: subagents already stay out of the user's way.

Subagents **never notify the user**. They report to you, and you decide what is worth telling the user. Check on them with `sessions.wait` rather than leaving them unattended.

### Beside you (`shared`)

Shares your workspace and checkout:

```js
;async () => {
  const helper = await tools.codevisor.sessions.create({
    harnessId: "codex",
    title: "Second opinion on the retry logic"
  }) // workspacePlacement defaults to "shared"
  await tools.codevisor.sessions.prompt({
    sessionId: helper.id,
    text: "Review the uncommitted changes in src/retry.ts and suggest fixes. Don't edit files."
  })
  return helper.id
}
```

Since the checkout is shared, give it a scoped task, and don't edit the same files at the same time.

### With its own worktree (`owned`)

```js
;async () => {
  const me = await tools.codevisor.context.current()
  const harnesses = await tools.codevisor.harnesses.list()
  const worktree = await tools.codevisor.worktrees.create({
    projectId: me.projectId,
    name: "abc-123"
  })
  const session = await tools.codevisor.sessions.create({
    workspacePlacement: "owned",
    harnessId: "claude-code", // pick a ready harness id from harnesses.list()
    title: "Fix ABC-123: login redirect loop",
    worktreeName: worktree.name, // must name an existing worktree
    labels: { linear: "ABC-123", role: "worker" }
  })
  await tools.codevisor.sessions.prompt({
    sessionId: session.id,
    text: "Fix ABC-123 … then open a PR."
  })
  return session.id
}
```

### A separate line of work (`independent`)

Only when the user asked for it ("start an agent for each of these issues that I'll follow up on"):

```js
;async () =>
  tools.codevisor.sessions.create({
    workspacePlacement: "independent",
    harnessId: "claude-code",
    title: "Billing export",
    labels: { linear: "ABC-200" }
  })
```

- Sessions you create record you as `parentSessionId`, whatever their placement.
- `labels` are free-form key/value pairs. Use them to find your agents again later.
- An agent on another machine (see below) can't be owned by your workspace; it is always independent.

### Promoting a subagent

If a subagent's work turns into something the user should manage directly, promote its workspace with `workspaces.update({ workspaceId, parentWorkspaceId: null })`. It becomes a top-level sidebar row and no longer archives with you. The user can do the same from its tab group's menu.

## Wait instead of polling

```js
;async () =>
  tools.codevisor.sessions.wait({
    ids: [a, b, c],
    until: ["idle", "waitingForUser", "errored"],
    timeoutMs: 240000
  })
// → { sessions: [{ id, sidebarState, actionRequiredKind?, pendingQuestion? }], timedOut }
```

- It returns as soon as any listed session reaches one of the `until` states.
- Call it again with the remaining ids to keep waiting.
- `timedOut: true` is normal; check state and wait again.

## Check progress and answer questions

- `sessions.get({ sessionId })`: status, current conversation, queue.
- `sessions.transcript({ sessionId, limit })`: recent items, newest page first. Use `before` for older pages.
- `sessions.list({ parentSessionId: me.sessionId })` or `sessions.list({ label: "linear=ABC-123" })`: rediscover your agents.
- When `sidebarState` is `waitingForUser`:
  - Read `pendingQuestion`.
  - Answer with `sessions.question_answer({ sessionId, questionId, outcome: "answered", answers })`, or send guidance with `sessions.prompt`.
- `sessions.cancel({ sessionId })` stops the active turn.

## If you are the child

If `context.current()` has a `parentSessionId`, you are someone's subagent: report to your parent, not the user. When you are blocked or done, tell your parent directly:

```js
;async () => {
  const me = await tools.codevisor.context.current()
  await tools.codevisor.sessions.prompt({
    sessionId: me.parentSessionId,
    text: `Question from ${me.sessionId}: …`
  })
}
```

## Review and clean up

- To review work, start another session on the same project with `labels: { role: "reviewer", for: workerId }` and prompt it with the PR or branch.
- `sessions.branch_diff({ sessionId })` gives a quick size of an agent's changes.
- To archive a workspace, use `workspaces.update({ workspaceId, isArchived: true })` (the session's `workspaceId` is on its summary). Archiving a workspace also archives the `owned` workspaces under it. `workspaces.list({ label })` finds workspaces by label.
- Archive only workspaces you created, once their work is merged or no longer needed. Archiving keeps a restorable snapshot but releases the branch name, so push or open the PR first if the branch should stay around.

## Agents on other machines

The same tools exist on every machine. `(await machines.get("macbook")).tools.codevisor.sessions.create(…)` starts an agent there. See `codevisor-machines`.
