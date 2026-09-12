---
name: tophat
description: Run a development change and test it through realistic user workflows. Use when asked to tophat, manually verify a feature or fix, smoke-test a branch or PR, or check that an implemented change actually works in the app.
---

# Tophat

Put on the user's hat: run the change, exercise the affected workflow, and
report what you observed. Inspired by Shopify's practice of manually trying
changes during PR review, this skill adapts that approach to Codevisor
development. A build or passing automated tests alone cannot establish that
the user workflow works.

## Identify the change

- Use the feature, bug, branch, or PR named in the conversation. Otherwise,
  inspect the current worktree's staged and unstaged changes, including new
  files, then its branch diff against the appropriate base. Read enough code
  and context to understand the intended behavior and affected surfaces.
- State the user-visible outcome in one sentence. For a bug fix, identify the
  original trigger and what should happen after the fix.
- Record the worktree, revision, and relevant uncommitted changes. Preserve
  existing work; use an isolated worktree when another revision needs testing.
  Reuse a matching build only when you can establish that it contains the
  change, including any relevant local edits.
- Treat a tophat request as authorization for the normal local setup and
  interactions needed to verify that change. Ask for missing requirements
  only when the intended behavior cannot be inferred; continue independent
  checks while waiting.

## Choose a small set of scenarios

Before interacting, describe the setup, user actions, and expected observable
result for each scenario. Scale the scope to the change:

1. **Main workflow:** follow the ordinary path from its entry point to the
   completed result. For a fix, exercise the reported reproduction steps.
2. **Relevant edge or recovery path:** choose a case suggested by the change,
   such as empty input, cancellation, retry, a long value, or reconnecting.
3. **Nearby regression:** exercise an existing behavior that shares the changed
   component or state. Check persistence or cross-device synchronization when
   the change affects it.

For shared native behavior, cover macOS and iOS. For a platform-specific
change, focus on that platform. Choose scenarios for their ability to expose
mistakes; do not expand every change into a full product audit.

## Run the right environment

Read the relevant skills and follow their current instructions:

- [run-dev](../run-dev/SKILL.md) owns development startup and runner lifecycle.
  Use `bun run dev` for both native apps, `bun run dev:macos` or
  `bun run dev:ios` for one platform, and `bun run dev:web` for the website.
  Reuse this worktree's matching instance when possible. Track processes you
  start and respect the one-runner-per-worktree rule.
- [ios-development](../ios-development/SKILL.md) owns iOS Simulator inspection
  and interaction, including Xcode setup and tool selection.
- Use the available `computer-use` skill for macOS app interaction and
  recordings, and `browser-use` for website interaction. Load these skills
  from the current skill catalog instead of guessing tool APIs.

Confirm that the running app and backend belong to the intended worktree and
contain the change before testing. Use development data and the real runtime
path affected by the change. For a CLI or backend-only change, exercise its
actual command or API and inspect the observable result. Do not substitute
mocked responses for the integration being verified.

## Exercise, observe, and investigate

- Perform the scenarios through the real interface. Inspect the resulting
  screen or state after each meaningful action; a successfully delivered click
  does not prove that the feature worked.
- Check the interaction details touched by the change, such as focus, keyboard
  behavior, navigation, layout, loading feedback, and error recovery. Wait for
  observable conditions instead of relying on arbitrary sleeps.
- Capture concise evidence of the result. A screenshot suits a visible state;
  a short recording suits an interaction, animation, or cross-device flow.
  Inspect captured evidence before using it to support a conclusion. Use the
  available `attaching-files` skill to share files in the final response.
- If a scenario fails, record reproduction steps and expected versus actual
  behavior, then inspect relevant logs or state to narrow the cause. Compare
  against the base revision when needed to establish whether it is a regression.
- When the task includes implementation or fixes, repair defects within that
  scope and rerun the failed scenario plus affected nearby checks. For a
  review-only request, report findings without changing the implementation.
  If adding or changing automated regression tests, follow
  [deterministic-tests](../deterministic-tests/SKILL.md).
- Complete required automated checks as supporting evidence. Reuse relevant
  results for the same code state; repeat checks when changes invalidate them.
  If setup or tooling prevents a scenario, mark it blocked and continue other
  useful checks. Never count an unexecuted scenario as a pass.

## Report the result

Lead with **Passed**, **Issues found**, or **Blocked** for the stated scope.
Use **Issues found** when a defect remains, even if other checks were
blocked. Use **Passed** only when the planned scenarios were executed against
the final change and passed; disclose any remaining gaps.

Keep the report short and reproducible:

- Revision/local changes, platform, and environment tested.
- Scenarios performed and their observed outcomes, with evidence links where
  useful. Separate direct observations from automated check results.
- Any defects and fixes, reproduction steps for unresolved issues, and checks
  that could not be completed with the specific blocker.
- Whether a development instance was left running for the user to inspect.

Clean up temporary test data and resources you created when appropriate.
Stop only processes you own when they are no longer needed. A tophat result
reports verification; it does not itself publish a review, merge, or release.

## Inspiration

- [Shopify: Tophatting in React Native](https://shopify.engineering/tophatting-react-native)
- [Shopify: Tophat, crafting a delightful mobile developer experience](https://shopify.engineering/shopify-tophat-mobile-developer-testing)
