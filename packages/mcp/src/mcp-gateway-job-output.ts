import { appendFile, mkdir, rm } from "node:fs/promises"
import { join } from "node:path"

export interface JobOutputFile {
  readonly append: (text: string) => void
  readonly flushed: () => Promise<void>
}

export interface JobOutputDirectory {
  readonly path: string
  readonly ready: () => Promise<void>
}

export const jobOutputDirectory = (dataDir: string): JobOutputDirectory => {
  const path = join(dataDir, "execution-jobs")
  let prepared: Promise<void> | undefined
  return {
    path,
    ready: () => {
      prepared ??= freshDirectory(path)
      return prepared
    }
  }
}

export const makeJobOutputFile = (ready: Promise<void>, path: string): JobOutputFile => {
  let chain = ready
  return {
    append: (text) => {
      chain = chain.then(() => appendFile(path, text)).catch(() => undefined)
    },
    flushed: () => chain
  }
}

const freshDirectory = (path: string): Promise<void> =>
  rm(path, { recursive: true, force: true })
    .then(() => mkdir(path, { recursive: true }))
    .then(
      () => undefined,
      () => undefined
    )
