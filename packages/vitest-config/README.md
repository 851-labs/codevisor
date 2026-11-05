# @codevisor/vitest-config

The Vitest settings every package shares. Wrap a package's config in
`defineTestConfig` instead of `defineConfig`:

```ts
import { defineTestConfig } from "@codevisor/vitest-config"

export default defineTestConfig({
  test: { include: ["src/**/*.test.ts"] }
})
```

## Test files share loaded code

Each package's tests run as two Vitest projects:

- **shared**: every `*.test.ts` file. A worker loads the package's modules
  once and reuses them for every file it runs (`isolate: false`), so a test
  file doesn't pay to import the whole app again.
- **isolated**: every `*.isolated.test.ts` file. Each file gets fresh modules,
  as Vitest does by default.

Name a test file `*.isolated.test.ts` when it replaces a module with
`vi.mock`, `vi.doMock`, or `vi.resetModules`. A module mock only takes effect
for modules loaded after it, and in a shared worker an earlier file has
usually loaded them already.

Because modules are loaded once per worker:

- Don't register `beforeEach`/`afterEach`/`beforeAll`/`afterAll` at the top
  level of a support module. It runs only for the first file that imports it.
  Register cleanup with `onTestFinished` when you create the resource, or put
  hooks every file needs in the package's `src/test-setup.ts` (listed in
  `setupFiles`), which runs before every test file.
- Module-level state in support modules lives for the whole worker. Keep it
  immutable, or reset it from a hook.

## State resets and order

`restoreMocks`, `unstubEnvs`, and `unstubGlobals` undo `vi.spyOn`,
`vi.stubEnv`, and `vi.stubGlobal` before each test, so a forgotten restore
cannot leak into the next test or file. Create spies and stubs in the test or
in `beforeEach`, not in `beforeAll`.

Files and tests run in a random order (`sequence.shuffle`). Vitest prints the
seed (`Running tests with seed "…"`); rerun a failure with
`--sequence.seed=<seed>`.
