import { randomUUID } from "node:crypto"
import {
  lstat,
  mkdir,
  mkdtemp,
  readFile,
  readdir,
  rename,
  rm,
  rmdir,
  unlink,
  writeFile
} from "node:fs/promises"
import { dirname, join } from "node:path"
import { setTimeout as sleep } from "node:timers/promises"

const processIsAlive = (pid) => {
  try {
    process.kill(pid, 0)
    return true
  } catch (error) {
    return error.code === "EPERM"
  }
}

const removeEmpty = async (path) => {
  try {
    await rmdir(path)
  } catch (error) {
    if (!["ENOENT", "ENOTEMPTY", "EEXIST", "ENOTDIR"].includes(error.code)) throw error
  }
}

const removeOwner = async (path, name) => {
  try {
    await unlink(join(path, name))
  } catch (error) {
    if (error.code !== "ENOENT") throw error
  }
}

const cleanStale = async (path, isProcessAlive) => {
  let info
  try {
    info = await lstat(path)
  } catch (error) {
    if (error.code === "ENOENT") return
    throw error
  }
  if (!info.isDirectory()) {
    const owner = Number.parseInt(await readFile(path, "utf8").catch(() => ""), 10)
    if (Number.isInteger(owner) && (await isProcessAlive(owner))) return
    try {
      await unlink(path)
    } catch (error) {
      if (!["ENOENT", "EISDIR", "EPERM"].includes(error.code)) throw error
    }
    return
  }
  let names
  try {
    names = await readdir(path)
  } catch (error) {
    if (error.code === "ENOENT") return
    throw error
  }
  for (const name of names) {
    const match = /^owner-(\d+)-/.exec(name)
    if (match === null) throw new Error(`Invalid artifact lock entry: ${join(path, name)}`)
    if (await isProcessAlive(Number(match[1]))) return
  }
  for (const name of names) {
    try {
      await unlink(join(path, name))
    } catch (error) {
      if (error.code !== "ENOENT") throw error
    }
  }
  await removeEmpty(path)
}

export async function withArtifactLock(
  lockPath,
  action,
  { retryDelay = () => sleep(250), isProcessAlive = processIsAlive, pid = process.pid } = {}
) {
  await mkdir(dirname(lockPath), { recursive: true })
  const staging = await mkdtemp(`${lockPath}.pending-`)
  const ownerName = `owner-${pid}-${randomUUID()}`
  try {
    await writeFile(join(staging, ownerName), String(pid), { flag: "wx" })
    for (;;) {
      try {
        await rename(staging, lockPath)
        break
      } catch (error) {
        if (!["EEXIST", "ENOTEMPTY", "ENOTDIR", "EISDIR"].includes(error.code)) throw error
      }
      await cleanStale(lockPath, isProcessAlive)
      const occupied = await lstat(lockPath).then(
        () => true,
        (error) => {
          if (error.code !== "ENOENT") throw error
          return false
        }
      )
      if (occupied) await retryDelay()
    }
    try {
      return await action()
    } finally {
      await removeOwner(lockPath, ownerName)
      await removeEmpty(lockPath)
    }
  } finally {
    await rm(staging, { recursive: true, force: true })
  }
}
