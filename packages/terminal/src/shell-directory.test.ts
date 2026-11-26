import { expect, it } from "vitest"

import { shellDirectory } from "./shell-directory.js"

it.each([
  ["kitty-shell-cwd://host/Users/me/a b%20c", "/Users/me/a b%20c"],
  ["file://host/Users/me/a%20b", "/Users/me/a b"],
  ["/Users/me/plain", "/Users/me/plain"],
  ["file://host/bad%zz", undefined],
  ["file://host", undefined],
  ["", undefined]
])("reads the folder a shell reported in %j", (reported, folder) => {
  expect(shellDirectory(reported)).toBe(folder)
})
