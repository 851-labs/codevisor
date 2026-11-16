import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { expect, it, onTestFinished } from "vitest"

import { namedDownloadPath } from "./browser-downloads.js"

const downloads = () => {
  const directory = mkdtempSync(join(tmpdir(), "browser-downloads-"))
  onTestFinished(() => rmSync(directory, { recursive: true, force: true }))
  return directory
}

const download = (guid: string, suggestedFilename: string, path?: string) => ({
  guid,
  url: "https://example.com/file",
  suggestedFilename,
  ...(path === undefined ? {} : { path })
})

it("gives a stored download its suggested name, once", () => {
  const directory = downloads()
  writeFileSync(join(directory, "one"), "report")
  const named = join(directory, "named", "one", "report.csv")

  expect(namedDownloadPath(directory, download("one", "report.csv"))).toBe(named)
  expect(namedDownloadPath(directory, download("one", "report.csv"))).toBe(named)
  expect(readFileSync(named, "utf8")).toBe("report")
})

it("keeps a name inside the downloads folder whatever the page suggests", () => {
  const directory = downloads()
  for (const guid of ["two", "three", "four"]) writeFileSync(join(directory, guid), guid)

  expect(namedDownloadPath(directory, download("two", "../../etc/passwd"))).toBe(
    join(directory, "named", "two", "passwd")
  )
  expect(namedDownloadPath(directory, download("three", "..\\\\..\\\\evil.exe"))).toBe(
    join(directory, "named", "three", "evil.exe")
  )
  expect(namedDownloadPath(directory, download("four", ".."))).toBe(
    join(directory, "named", "four", "download")
  )
})

it("leaves a path the browser chose, and a download whose file is missing, alone", () => {
  const directory = downloads()

  expect(namedDownloadPath(directory, download("five", "a.txt", "/Users/me/Downloads/a.txt"))).toBe(
    "/Users/me/Downloads/a.txt"
  )
  expect(namedDownloadPath(directory, download("six", "b.txt"))).toBe(join(directory, "six"))
})
