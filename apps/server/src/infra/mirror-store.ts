import { appendFile, mkdir, readdir, readFile, rm, stat, writeFile } from "node:fs/promises"
import { join } from "node:path"

import { git, gitWithInput } from "./sync-git.js"

export interface PreparedMirror {
  readonly path: string
  readonly head?: string | undefined
}

export interface OwnedMirror {
  readonly mirrorId: string
  readonly owner: string
}

export interface MirrorStore {
  readonly prepare: (mirrorId: string, name: string, owner: string) => Promise<PreparedMirror>
  readonly write: (mirrorId: string, offset: number, data: Buffer) => Promise<void>
  readonly apply: (mirrorId: string, commit: string) => Promise<PreparedMirror>
  readonly remove: (mirrorId: string) => Promise<void>
  readonly owned: () => Promise<ReadonlyArray<OwnedMirror>>
}

export const makeMirrorStore = (root: string): MirrorStore => {
  const layout = (mirrorId: string) => mirrorLayout(root, mirrorId)

  return {
    prepare: async (mirrorId, name, owner) => {
      const paths = layout(mirrorId)
      const existing = await readMeta(paths.meta)
      const meta = existing ?? (await createMirror(root, paths, name))
      if (meta.owner !== owner) await writeMeta(paths.meta, { ...meta, mirrorId, owner })
      await rm(paths.pendingPack, { force: true })
      return { path: meta.path, head: await headOf(paths.gitDir) }
    },
    write: async (mirrorId, offset, data) => {
      const paths = layout(mirrorId)
      await requireOffset(paths.pendingPack, offset)
      await appendFile(paths.pendingPack, data)
    },
    apply: async (mirrorId, commit) => {
      const paths = layout(mirrorId)
      const meta = await requireMeta(paths.meta, mirrorId)
      await indexPendingPack(paths)
      await checkOut(paths.gitDir, meta.path, commit)
      return { path: meta.path, head: commit }
    },
    remove: async (mirrorId) => {
      const paths = layout(mirrorId)
      const meta = await readMeta(paths.meta)
      if (meta !== undefined) await rm(meta.path, { recursive: true, force: true })
      await rm(paths.store, { recursive: true, force: true })
    },
    owned: async () => {
      const stores = await readdir(join(root, ".store")).catch(() => [])
      const metas = await Promise.all(stores.map((store) => readMeta(layout(store).meta)))
      return metas.flatMap((meta) =>
        meta?.mirrorId === undefined || meta.owner === undefined
          ? []
          : [{ mirrorId: meta.mirrorId, owner: meta.owner }]
      )
    }
  }
}

interface MirrorLayout {
  readonly store: string
  readonly gitDir: string
  readonly meta: string
  readonly pendingPack: string
}

interface MirrorMeta {
  readonly path: string
  readonly mirrorId?: string
  readonly owner?: string
}

const mirrorLayout = (root: string, mirrorId: string): MirrorLayout => {
  const store = join(root, ".store", safeSegment(mirrorId))
  return {
    store,
    gitDir: join(store, "git"),
    meta: join(store, "mirror.json"),
    pendingPack: join(store, "incoming.pack")
  }
}

const createMirror = async (
  root: string,
  paths: MirrorLayout,
  name: string
): Promise<MirrorMeta> => {
  const path = join(root, `${safeSegment(name)}-${safeSegment(paths.store).slice(-8)}`)
  await mkdir(path, { recursive: true })
  await mkdir(paths.store, { recursive: true })
  await git(["init", "--bare", "--quiet", paths.gitDir])
  const meta = { path }
  await writeMeta(paths.meta, meta)
  return meta
}

const writeMeta = (path: string, meta: MirrorMeta): Promise<void> =>
  writeFile(path, JSON.stringify(meta))

const readMeta = async (path: string): Promise<MirrorMeta | undefined> => {
  const text = await readFile(path, "utf8").catch(() => undefined)
  if (text === undefined) return undefined
  const fields: unknown = JSON.parse(text)
  if (!isRecord(fields) || typeof fields.path !== "string") return undefined
  return {
    path: fields.path,
    ...(typeof fields.mirrorId === "string" ? { mirrorId: fields.mirrorId } : {}),
    ...(typeof fields.owner === "string" ? { owner: fields.owner } : {})
  }
}

const requireMeta = async (path: string, mirrorId: string): Promise<MirrorMeta> => {
  const meta = await readMeta(path)
  if (meta === undefined) throw new Error(`No mirror ${mirrorId} on this machine; prepare it first`)
  return meta
}

const headOf = async (gitDir: string): Promise<string | undefined> => {
  const head = await git(["--git-dir", gitDir, "rev-parse", "--verify", "--quiet", SYNC_REF]).catch(
    () => ""
  )
  return head.trim() === "" ? undefined : head.trim()
}

const requireOffset = async (path: string, offset: number): Promise<void> => {
  const size = (await stat(path).catch(() => undefined))?.size ?? 0
  if (size !== offset) throw new Error(`Mirror upload expected offset ${size}, got ${offset}`)
}

const indexPendingPack = async (paths: MirrorLayout): Promise<void> => {
  const pack = await readFile(paths.pendingPack).catch(() => undefined)
  if (pack === undefined || pack.length === 0) return
  await gitWithInput(["--git-dir", paths.gitDir, "index-pack", "--stdin", "--fix-thin"], pack)
  await rm(paths.pendingPack, { force: true })
}

const checkOut = async (gitDir: string, workTree: string, commit: string): Promise<void> => {
  await git(["--git-dir", gitDir, "--work-tree", workTree, "read-tree", "-u", "--reset", commit])
  await git(["--git-dir", gitDir, "update-ref", SYNC_REF, commit])
}

const SYNC_REF = "refs/heads/sync"

const safeSegment = (value: string): string =>
  value.replace(/[^A-Za-z0-9._-]+/g, "-").replace(/^-+|-+$/g, "") || "workspace"

const isRecord = (value: unknown): value is Record<string, unknown> =>
  typeof value === "object" && value !== null
