---
name: linear-ticket
description: Work a Linear ticket end to end — status, implementation, tophat, PR, and evidence on the ticket. Use when asked to work on, pick up, or ship a Linear issue (e.g. 851-1234), or when creating tickets for new work.
---

# Linear ticket workflow

Use the Linear integration (via Codevisor) for every ticket step.

## Creating tickets

Put tickets in the **codevisor** project and assign them to the person
driving the chat: pass `assignee: "me"`, which resolves to the Linear
account the integration is signed in as (`get_user` with `query: "me"`
shows who that is).
Link each one to its parent tracking ticket when one exists. Don't start
work on a ticket just because you created it.

## Working a ticket

1. **Start:** move the ticket to **In Progress**. Branch from `origin/main`
   using the ticket's `gitBranchName`.
2. **Clarify, then implement.** Read the ticket and the code it touches.
   Before writing code, ask the user about open questions: ambiguous
   behavior, "optional/discuss" items, or anything the code contradicts.
   Record the answers on the ticket as a comment. If nothing is unclear,
   go straight to implementing.
3. **Tophat:** follow the `tophat` skill. Capture evidence: a screen
   recording for interactions, screenshots for static UI.
4. **Open a PR** with the diff. The lefthook pre-commit hook runs
   `bun run check`, so don't skip it. If it can't run on your machine,
   say so in the PR and note what you ran instead.
   - Title: `<summary> (<ticket id>)`.
   - Body: `Fixes <ticket id>`, a short summary, tophat notes and the
     tophat assets.
5. **Comment on the ticket** with the tophat assets and a link to the PR.
   To upload a file: `prepare_attachment_upload`, then `PUT` the bytes
   with the signed headers exactly as returned, then
   `create_attachment_from_upload`.
6. **Merge only after the user approves.** Squash-merge. The ticket closes
   through `Fixes`.
