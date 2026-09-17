import { mkdirSync, writeFileSync } from "node:fs"
import { dirname, join } from "node:path"

import { expect, it, vi, onTestFinished } from "vitest"

import { detectGitLocation, migrateProjectLocationState } from "./project-location-state.js"
import { memoryDatabase, run, tempDatabase } from "./test-support.js"

it("detects repositories once, including nested folders, and excludes scratch workspaces", async () => {
  const root = dirname(tempDatabase())
  vi.stubEnv("CODEVISOR_WORKTREES_ROOT", root)
  onTestFinished(() => {
    vi.unstubAllEnvs()
  })
  const file = join(root, "file")
  writeFileSync(file, "text")
  expect(detectGitLocation(file)).toBe(false)
  expect(detectGitLocation(join(root, "missing"))).toBe(false)
  expect(detectGitLocation(root)).toBe(false)
  mkdirSync(join(root, ".git"))
  mkdirSync(join(root, "nested"))
  mkdirSync(join(root, "workspaces", "scratch"), { recursive: true })
  expect(detectGitLocation(join(root, "nested"))).toBe(true)
  expect(detectGitLocation(join(root, "workspaces", "scratch"))).toBe(false)
  const { sqlite, project, db } = await memoryDatabase()
  sqlite
    .prepare(
      "update project_locations set folder_path = ?, is_git_repository = null where project_id = ?"
    )
    .run(root, project.id)
  expect((await run(db.listProjects))[0]!.locations[0]).not.toHaveProperty("isGitRepository")
  migrateProjectLocationState(sqlite)
  expect(
    sqlite
      .prepare("select is_git_repository from project_locations where project_id = ?")
      .get(project.id)
  ).toEqual({ is_git_repository: 1 })
  sqlite
    .prepare("update project_locations set folder_path = ? where project_id = ?")
    .run(join(root, "workspaces", "scratch"), project.id)
  expect((await run(db.listProjects))[0]!.isScratch).toBe(true)
})
