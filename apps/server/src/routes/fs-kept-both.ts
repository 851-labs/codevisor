import { basename, dirname, extname, join } from "node:path"

import { HttpFailure } from "../server-context.js"
import { stringField } from "../unknown-values.js"

export type NameShape = "file" | "folder"

const maxCopies = 10_000

export const claimKeptBothPath = async (
  path: string,
  shape: NameShape,
  claim: (candidate: string) => Promise<void>
): Promise<string> => {
  for (const candidate of keptBothCandidates(path, shape)) {
    if (await claimed(candidate, claim)) return candidate
  }
  throw new HttpFailure(409, `Too many copies of ${path}`, "name_taken")
}

export const keptBothCandidates = function* (path: string, shape: NameShape): Generator<string> {
  yield path
  const { stem, extension } = splitName(basename(path), shape)
  for (let copy = 2; copy <= maxCopies; copy += 1) {
    yield join(dirname(path), `${stem} ${copy}${extension}`)
  }
}

const claimed = async (
  candidate: string,
  claim: (candidate: string) => Promise<void>
): Promise<boolean> => {
  try {
    await claim(candidate)
    return true
  } catch (cause) {
    if (stringField(cause, "code") === "EEXIST") return false
    throw cause
  }
}

interface SplitName {
  readonly stem: string
  readonly extension: string
}

const splitName = (name: string, shape: NameShape): SplitName => {
  const extension = shape === "file" ? extname(name) : ""
  return { stem: name.slice(0, name.length - extension.length), extension }
}
