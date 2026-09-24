# VNC relay backpressure coverage

The Alpha run at `20218b853c71c1df4964bc77c59122e86dfa00ab` passed all
725 server tests but missed the pause/resume branches in
`screen-sharing-vnc.ts`. Sending 8 MiB over loopback did not guarantee that
the WebSocket send queue filled on the Linux runner.

Replace that test with a controlled WebSocket queue and send completions,
using the existing injected upstream connection. Assert that the real
upstream Socket pauses at and above the limit, stays paused while the queue
is still at the limit, resumes below it, and does not resume redundantly.
The existing real-socket tests still exercise bidirectional byte forwarding,
control arbitration, authentication, and connection teardown.

Validation:

- All 19 VNC route tests pass with shuffled seeds 54 and 2338.
- Full server coverage: 133 files, 725 tests passed and one existing
  platform-specific test skipped on macOS; statements, branches, functions,
  and lines all 100%.
- `bun run check:js` passes, including the repository's coverage gates.
- Native VNC and rig suites: see `coverage-validate.md`.

The change affects only TypeScript test code. Native interop, benchmarking,
and rig UI tophat are skipped under the unaffected-layer exception in
`docs/plans/vnc-validation.md`: no production protocol, transport, rendering,
or performance behavior changes. The affected developer workflow was
exercised through the actual coverage and release-check commands above.
TestFlight publishing and all coverage thresholds remain unchanged.
