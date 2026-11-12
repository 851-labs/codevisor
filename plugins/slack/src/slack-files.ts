import { mkdir, readFile, stat, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { basename, join } from "node:path"

export interface LocalFile {
  name: string
  bytes: Uint8Array<ArrayBuffer>
}

export interface SlackFiles {
  save(fileId: string, name: string, bytes: Uint8Array): Promise<string>
  read(path: string): Promise<LocalFile>
}

export const maxUploadBytes = 100 * 1024 * 1024

export const localSlackFiles = (directory = join(tmpdir(), "codevisor-slack")): SlackFiles => ({
  save: async (fileId, name, bytes) => {
    const folder = join(directory, fileId)
    await mkdir(folder, { recursive: true })
    const path = join(folder, safeName(name))
    await writeFile(path, bytes)
    return path
  },
  read: async (path) => {
    if ((await stat(path)).size > maxUploadBytes)
      throw new Error("That file is over Slack's 100 MB upload limit here.")

    return { name: basename(path), bytes: new Uint8Array(await readFile(path)) }
  }
})

const safeName = (name: string): string => basename(name).replaceAll(/[^\w.\- ]/g, "_") || "file"
