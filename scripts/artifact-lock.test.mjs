import assert from "node:assert/strict"
import { mkdtemp, readFile, rm, stat, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"
import test from "node:test"

import { withArtifactLock } from "./artifact-lock.mjs"

const lockFixture = async (t) => {
  const root = await mkdtemp(join(tmpdir(), "artifact-lock-"))
  t.after(() => rm(root, { recursive: true, force: true }))
  return join(root, "nested", ".lock")
}

const deferred = () => {
  let resolve
  const promise = new Promise((r) => {
    resolve = r
  })
  return { promise, resolve }
}

test("runs the action holding the lock and releases it afterwards", async (t) => {
  const lockPath = await lockFixture(t)
  const result = await withArtifactLock(
    lockPath,
    async () => {
      assert.equal(await readFile(lockPath, "utf8"), String(process.pid))
      return "done"
    },
    { retryDelay: () => assert.fail("no contention expected") }
  )
  assert.equal(result, "done")
  await assert.rejects(stat(lockPath))
})

test("releases the lock when the action throws", async (t) => {
  const lockPath = await lockFixture(t)
  await assert.rejects(
    withArtifactLock(lockPath, async () => {
      throw new Error("boom")
    }),
    /boom/
  )
  await assert.rejects(stat(lockPath))
})

test("a second acquirer waits for the holder to release, then proceeds", async (t) => {
  const lockPath = await lockFixture(t)
  const holderMayFinish = deferred()
  const holderEntered = deferred()
  const holder = withArtifactLock(
    lockPath,
    () => {
      holderEntered.resolve()
      return holderMayFinish.promise
    },
    { retryDelay: () => assert.fail("holder must not wait") }
  )
  // Start the waiter only once the holder is inside its action, i.e. provably
  // owns the lock file. Both acquirers first await a mkdir, so starting them
  // back to back would leave which one creates the lock to scheduler luck.
  await holderEntered.promise
  // The waiter observes contention exactly once, then is released only after
  // the holder has finished and removed the lock — no timing involved.
  const waiterSawContention = deferred()
  const waiterMayRetry = deferred()
  let waiterEntered = false
  const waiter = withArtifactLock(
    lockPath,
    async () => {
      waiterEntered = true
    },
    {
      pid: process.pid + 1,
      retryDelay: () => {
        waiterSawContention.resolve()
        return waiterMayRetry.promise
      }
    }
  )
  await waiterSawContention.promise
  assert.equal(waiterEntered, false)

  holderMayFinish.resolve("held")
  assert.equal(await holder, "held")
  await assert.rejects(stat(lockPath), "holder released the lock")

  waiterMayRetry.resolve()
  await waiter
  assert.equal(waiterEntered, true)
  await assert.rejects(stat(lockPath))
})

test("a lock left by a dead process is taken over without waiting", async (t) => {
  const lockPath = await lockFixture(t)
  await rm(join(lockPath, ".."), { recursive: true, force: true })
  await withArtifactLock(lockPath, () => undefined, { retryDelay: () => assert.fail("unused") })
  await writeFile(lockPath, "999999")
  let entered = false
  await withArtifactLock(
    lockPath,
    () => {
      entered = true
    },
    { isProcessAlive: () => false, retryDelay: () => assert.fail("stale locks must not wait") }
  )
  assert.equal(entered, true)
})

test("a lock held by a live process is respected", async (t) => {
  const lockPath = await lockFixture(t)
  await withArtifactLock(lockPath, () => undefined)
  await writeFile(lockPath, "4242")
  let retries = 0
  await withArtifactLock(lockPath, () => undefined, {
    isProcessAlive: (pid) => pid === 4242,
    retryDelay: async () => {
      retries += 1
      // The owner finishes: it removes its lock.
      await rm(lockPath, { force: true })
    }
  })
  assert.equal(retries, 1)
})
