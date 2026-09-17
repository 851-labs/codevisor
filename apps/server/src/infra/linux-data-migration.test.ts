import { mkdtemp, mkdir, readFile, readlink, lstat, rm, symlink, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { afterEach, describe, expect, it, vi } from "vitest"

import {
  canonicalLinuxService,
  migrateLinuxDataLayout,
  moveLinuxDataEntry
} from "./linux-data-migration.js"

const faults = vi.hoisted(() => ({
  rename: undefined as ((source: string) => void) | undefined,
  stat: undefined as ((path: string) => Promise<void>) | undefined,
  write: undefined as ((path: string) => void) | undefined,
  link: undefined as (() => void) | undefined
}))
vi.mock("node:fs/promises", async (importOriginal) => {
  const original = await importOriginal<typeof import("node:fs/promises")>()
  return {
    ...original,
    symlink: async (...args: Parameters<typeof original.symlink>) => {
      faults.link?.()
      return original.symlink(...args)
    },
    rename: async (...args: Parameters<typeof original.rename>) => {
      faults.rename?.(String(args[0]))
      return original.rename(...args)
    },
    lstat: async (...args: Parameters<typeof original.lstat>) => {
      await faults.stat?.(String(args[0]))
      return original.lstat(...args)
    },
    writeFile: async (...args: Parameters<typeof original.writeFile>) => {
      faults.write?.(String(args[0]))
      return original.writeFile(...args)
    }
  }
})

const roots: string[] = []
afterEach(async () => {
  faults.rename = undefined
  faults.stat = undefined
  faults.write = undefined
  faults.link = undefined
  for (const root of roots.splice(0)) await rm(root, { recursive: true, force: true })
})

const fixture = async () => {
  const root = await mkdtemp(join(tmpdir(), "codevisor-linux-migration-"))
  roots.push(root)
  const source = join(root, "var", "data")
  const target = join(root, "home", ".codevisor", "data")
  await mkdir(source, { recursive: true })
  await mkdir(target, { recursive: true })
  const servicePath = join(root, "codevisor-server.service")
  const databasePath = join(target, "codevisor-server.sqlite")
  const unit = `[Service]\nExecStart=/opt/codevisor/bin/codevisor-server serve --port 51234 --db ${source}/codevisor-server.sqlite --auth token\nRestart=on-failure\n`
  await writeFile(servicePath, unit)
  const log = vi.fn()
  const reloadService = vi.fn(async () => {})
  const options = {
    layout: { databasePath, legacyDataDirectory: source },
    bootId: "migration-test",
    servicePath,
    reloadService,
    log
  }
  return { root, source, target, unit, options }
}

describe("Linux canonical data migration", () => {
  it("finishes a migration interrupted just before installing the legacy alias", async () => {
    const { source, target, options } = await fixture()
    await writeFile(join(source, "codevisor-server.sqlite"), "database")
    faults.link = () => {
      throw new Error("interrupted before alias")
    }
    await expect(migrateLinuxDataLayout(options)).rejects.toThrow("interrupted before alias")
    expect(await readFile(options.layout.databasePath, "utf8")).toBe("database")
    faults.link = undefined
    await migrateLinuxDataLayout(options)
    expect(await readlink(source)).toBe(target)
    await migrateLinuxDataLayout(options)
    expect(options.reloadService).toHaveBeenCalledOnce()
  })
  it("stages and verifies a cross-filesystem move and can retry a failed rename", async () => {
    const { source, target, options } = await fixture()
    await writeFile(join(source, "codevisor-server.sqlite"), "database")
    await mkdir(join(source, "attachments"))
    await writeFile(join(source, "attachments", "object"), "attachment")
    faults.rename = (path) => {
      if (path.startsWith(source + "/"))
        throw Object.assign(new Error("cross-device"), { code: "EXDEV" })
    }
    await migrateLinuxDataLayout(options)
    expect(await readFile(join(target, "attachments", "object"), "utf8")).toBe("attachment")
    expect(await readFile(options.layout.databasePath, "utf8")).toBe("database")
    const from = join(target, "from")
    const to = join(target, "to")
    await writeFile(from, "data")
    faults.rename = () => {
      throw Object.assign(new Error("permission denied"), { code: "EACCES" })
    }
    await expect(moveLinuxDataEntry(from, to)).rejects.toThrow("permission denied")
    expect(await readFile(from, "utf8")).toBe("data")
  })

  it("surfaces filesystem failures and handles a source removed while waiting for ownership", async () => {
    const { source, options } = await fixture()
    faults.stat = async (path) => {
      if (path === source) throw Object.assign(new Error("cannot inspect"), { code: "EACCES" })
    }
    await expect(migrateLinuxDataLayout(options)).rejects.toThrow("cannot inspect")
    let inspected = 0
    faults.stat = async (path) => {
      if (path === source && ++inspected === 2) await rm(source, { recursive: true })
    }
    await migrateLinuxDataLayout(options)
    expect(options.reloadService).toHaveBeenCalledOnce()
  })

  it("does not overwrite files or symlinks with a different shape", async () => {
    for (const shape of ["symlink", "directory", "size"]) {
      const { source, target, options } = await fixture()
      if (shape === "symlink") {
        await symlink("one", join(source, "entry"))
        await symlink("two", join(target, "entry"))
      } else {
        await writeFile(join(source, "entry"), "source")
        if (shape === "directory") await mkdir(join(target, "entry"))
        else await writeFile(join(target, "entry"), "longer destination")
      }
      await expect(migrateLinuxDataLayout(options)).rejects.toThrow("different data")
    }
  })

  it("supports installations without a systemd unit and preserves service backup failures", async () => {
    const { source, options } = await fixture()
    await rm(source, { recursive: true })
    const { servicePath, ...withoutService } = options
    await migrateLinuxDataLayout(withoutService)
    await migrateLinuxDataLayout({ ...options, servicePath: servicePath + ".missing" })
    expect(options.reloadService).not.toHaveBeenCalled()
    faults.write = (path) => {
      if (path.endsWith(".before-canonical-data"))
        throw Object.assign(new Error("backup denied"), { code: "EACCES" })
    }
    await expect(migrateLinuxDataLayout(options)).rejects.toThrow("backup denied")
  })
  it("moves the database and all sidecars, recovers a stranded login, and survives repeated starts", async () => {
    const { source, target, unit, options } = await fixture()
    for (const [name, value] of Object.entries({
      "codevisor-server.sqlite": "machine-and-projects",
      "codevisor-server.sqlite-wal": "pending-writes",
      "codevisor-server.sqlite-shm": "shared-memory",
      "mcp-secret-key": "encryption-key",
      "cloud-peer-pins.json": "peer-pins",
      "terminals.json": "terminal-state"
    }))
      await writeFile(join(source, name), value)
    await mkdir(join(source, "attachments"))
    await writeFile(join(source, "attachments", "example"), "attachment")
    await writeFile(join(target, "cloud.json"), "existing-login", { mode: 0o600 })
    await migrateLinuxDataLayout(options)
    await migrateLinuxDataLayout(options)
    expect(await readFile(join(target, "codevisor-server.sqlite"), "utf8")).toBe(
      "machine-and-projects"
    )
    expect(await readFile(join(target, "codevisor-server.sqlite-wal"), "utf8")).toBe(
      "pending-writes"
    )
    expect(await readFile(join(target, "mcp-secret-key"), "utf8")).toBe("encryption-key")
    expect(await readFile(join(target, "terminals.json"), "utf8")).toBe("terminal-state")
    expect(await readFile(join(target, "attachments", "example"), "utf8")).toBe("attachment")
    expect(await readFile(join(target, "cloud.json"), "utf8")).toBe("existing-login")
    expect((await lstat(join(target, "cloud.json"))).mode & 0o777).toBe(0o600)
    expect(await readlink(source)).toBe(target)
    expect(await readFile(options.servicePath, "utf8")).toContain(
      `--db "${options.layout.databasePath}"`
    )
    expect(await readFile(`${options.servicePath}.before-canonical-data`, "utf8")).toBe(unit)
    expect(options.reloadService).toHaveBeenCalledOnce()
    await expect(lstat(`${options.layout.databasePath}.lock`)).rejects.toMatchObject({
      code: "ENOENT"
    })
  })

  it("preflights every conflict before moving any data", async () => {
    const { source, target, options } = await fixture()
    await writeFile(join(source, "codevisor-server.sqlite"), "database")
    await writeFile(join(source, "cloud.json"), "account-a")
    await writeFile(join(target, "cloud.json"), "account-b")
    await expect(migrateLinuxDataLayout(options)).rejects.toThrow("different data")
    expect(await readFile(join(source, "codevisor-server.sqlite"), "utf8")).toBe("database")
    expect(await readFile(join(target, "cloud.json"), "utf8")).toBe("account-b")
    await expect(lstat(options.layout.databasePath)).rejects.toMatchObject({ code: "ENOENT" })
    await writeFile(join(target, "codevisor-server.sqlite"), "other-database")
    await expect(migrateLinuxDataLayout(options)).rejects.toThrow("Both copies were preserved")
    expect(options.reloadService).not.toHaveBeenCalled()
  })

  it("resumes an interrupted migration after the database moved", async () => {
    const { source, target, options } = await fixture()
    await writeFile(join(source, "codevisor-server.sqlite"), "database")
    await writeFile(join(source, "mcp-secret-key"), "key")
    await expect(
      migrateLinuxDataLayout({
        ...options,
        moveEntry: async (from, to) => {
          if (from.endsWith("mcp-secret-key")) throw new Error("interrupted")
          await moveLinuxDataEntry(from, to)
        }
      })
    ).rejects.toThrow("interrupted")
    expect(await readFile(options.layout.databasePath, "utf8")).toBe("database")
    await migrateLinuxDataLayout(options)
    expect(await readFile(join(target, "mcp-secret-key"), "utf8")).toBe("key")
    expect(await readlink(source)).toBe(target)
  })

  it("merges identical credentials, directories and symlinks without overwriting", async () => {
    const { source, target, options } = await fixture()
    for (const directory of [source, target]) {
      await writeFile(join(directory, "cloud.json"), "same-key")
      await mkdir(join(directory, "attachments"))
      await writeFile(join(directory, "attachments", "shared"), "same-object")
      await symlink("shared", join(directory, "attachments", "alias"))
    }
    await writeFile(join(source, "attachments", "new"), "new-object")
    await migrateLinuxDataLayout(options)
    expect(await readFile(join(target, "attachments", "new"), "utf8")).toBe("new-object")
    expect(await readlink(join(target, "attachments", "alias"))).toBe("shared")
  })

  it("reverses the old canonical-to-legacy symlink workaround", async () => {
    const { source, target, options } = await fixture()
    await writeFile(join(source, "cloud.json"), "key")
    await rm(target, { recursive: true })
    await symlink(source, target)
    await migrateLinuxDataLayout(options)
    expect((await lstat(target)).isDirectory()).toBe(true)
    expect(await readFile(join(target, "cloud.json"), "utf8")).toBe("key")
    expect(await readlink(source)).toBe(target)
  })

  it("leaves custom and non-Linux layouts untouched and upgrades empty legacy installs", async () => {
    const { source, target, options } = await fixture()
    await migrateLinuxDataLayout({
      ...options,
      layout: { databasePath: options.layout.databasePath }
    })
    expect(options.reloadService).not.toHaveBeenCalled()
    await rm(source, { recursive: true })
    await migrateLinuxDataLayout(options)
    expect((await lstat(target)).isDirectory()).toBe(true)
    expect(options.reloadService).toHaveBeenCalledOnce()
  })

  it("refuses unrelated symlink destinations", async () => {
    const { root, source, target, options } = await fixture()
    const unrelated = join(root, "unrelated")
    await mkdir(unrelated)
    await rm(target, { recursive: true })
    await symlink(unrelated, target)
    await expect(migrateLinuxDataLayout(options)).rejects.toThrow("custom data symlink")
    await rm(source, { recursive: true })
    await symlink(root, source)
    await expect(migrateLinuxDataLayout(options)).rejects.toThrow("unexpected legacy data symlink")
  })

  it("preserves custom service arguments and tolerates a stopped systemd", async () => {
    const { source, options, unit } = await fixture()
    await writeFile(`${options.servicePath}.before-canonical-data`, "original backup")
    await migrateLinuxDataLayout({
      ...options,
      reloadService: async () => {
        throw new Error("no bus")
      }
    })
    expect(options.log).toHaveBeenCalledWith(expect.stringContaining("reload was unavailable"))
    expect(await readFile(options.servicePath, "utf8")).toContain("--port 51234")
    expect(await readFile(`${options.servicePath}.before-canonical-data`, "utf8")).toBe(
      "original backup"
    )
    expect(
      canonicalLinuxService(
        unit.replace(`${source}/codevisor-server.sqlite`, "/custom/data.db"),
        `${source}/codevisor-server.sqlite`,
        "/new/data.db"
      )
    ).toContain("--db /custom/data.db")
  })
})
