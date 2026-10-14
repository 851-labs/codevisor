import { existsSync, readFileSync, readdirSync, renameSync, rmSync, writeFileSync } from "node:fs"
import { dirname, join, relative, sep } from "node:path"

const zipCrcTable = Array.from({ length: 256 }, (_, index) => {
  let value = index
  for (let bit = 0; bit < 8; bit += 1) {
    value = (value & 1) === 1 ? 0xedb88320 ^ (value >>> 1) : value >>> 1
  }
  return value >>> 0
})

const crc32 = (data: Buffer): number => {
  let value = 0xffffffff
  for (const byte of data) value = zipCrcTable[(value ^ byte) & 0xff]! ^ (value >>> 8)
  return (value ^ 0xffffffff) >>> 0
}

const extensionFiles = (directory: string): ReadonlyArray<string> => {
  const files: string[] = []
  for (const entry of readdirSync(directory, { withFileTypes: true })) {
    if (entry.name === ".DS_Store") continue
    const path = join(directory, entry.name)
    if (entry.isDirectory()) files.push(...extensionFiles(path))
    else if (entry.isFile()) files.push(path)
  }
  return files
}

const extensionArchiveName = (extension: string): string => {
  const manifest = JSON.parse(readFileSync(join(extension, "manifest.json"), "utf8")) as {
    name?: string
  }
  const name = (manifest.name ?? "Codevisor").replaceAll(/[/:\\]/g, "-").trim()
  return `${name === "" ? "Codevisor" : name}.zip`
}

export const browserExtensionArchivePath = (extension: string): string =>
  join(dirname(extension), extensionArchiveName(extension))

const localHeader = (
  nameBytes: Buffer,
  data: Buffer,
  checksum: number,
  fixedDosTime: number,
  fixedDosDate: number
): Buffer => {
  const local = Buffer.alloc(30)
  local.writeUInt32LE(0x04034b50, 0)
  local.writeUInt16LE(20, 4)
  local.writeUInt16LE(0x0800, 6)
  local.writeUInt16LE(0, 8)
  local.writeUInt16LE(fixedDosTime, 10)
  local.writeUInt16LE(fixedDosDate, 12)
  local.writeUInt32LE(checksum, 14)
  local.writeUInt32LE(data.length, 18)
  local.writeUInt32LE(data.length, 22)
  local.writeUInt16LE(nameBytes.length, 26)
  local.writeUInt16LE(0, 28)
  return local
}

const centralHeader = (
  nameBytes: Buffer,
  data: Buffer,
  checksum: number,
  fixedDosTime: number,
  fixedDosDate: number,
  localOffset: number
): Buffer => {
  const central = Buffer.alloc(46)
  central.writeUInt32LE(0x02014b50, 0)
  central.writeUInt16LE(0x0314, 4)
  central.writeUInt16LE(20, 6)
  central.writeUInt16LE(0x0800, 8)
  central.writeUInt16LE(0, 10)
  central.writeUInt16LE(fixedDosTime, 12)
  central.writeUInt16LE(fixedDosDate, 14)
  central.writeUInt32LE(checksum, 16)
  central.writeUInt32LE(data.length, 20)
  central.writeUInt32LE(data.length, 24)
  central.writeUInt16LE(nameBytes.length, 28)
  central.writeUInt16LE(0, 30)
  central.writeUInt16LE(0, 32)
  central.writeUInt16LE(0, 34)
  central.writeUInt16LE(0, 36)
  central.writeUInt32LE(0, 38)
  central.writeUInt32LE(localOffset, 42)
  return central
}

const endRecord = (
  centralParts: Buffer[],
  centralDirectory: Buffer,
  localOffset: number
): Buffer => {
  const end = Buffer.alloc(22)
  const entryCount = centralParts.length / 2
  end.writeUInt32LE(0x06054b50, 0)
  end.writeUInt16LE(0, 4)
  end.writeUInt16LE(0, 6)
  end.writeUInt16LE(entryCount, 8)
  end.writeUInt16LE(entryCount, 10)
  end.writeUInt32LE(centralDirectory.length, 12)
  end.writeUInt32LE(localOffset, 16)
  end.writeUInt16LE(0, 20)
  return end
}

const publishArchive = (
  extension: string,
  localParts: Buffer[],
  centralParts: Buffer[],
  localOffset: number
): string => {
  const centralDirectory = Buffer.concat(centralParts)
  const end = endRecord(centralParts, centralDirectory, localOffset)

  const archive = browserExtensionArchivePath(extension)
  const temporary = `${archive}.tmp-${process.pid.toString()}`
  rmSync(temporary, { force: true })
  writeFileSync(temporary, Buffer.concat([...localParts, centralDirectory, end]), { mode: 0o600 })
  renameSync(temporary, archive)
  return archive
}

export const createBrowserExtensionArchive = (extension: string): string => {
  if (!existsSync(join(extension, "manifest.json"))) {
    throw new Error("The Codevisor Chrome extension is missing")
  }
  const localParts: Buffer[] = []
  const centralParts: Buffer[] = []
  let localOffset = 0
  const fixedDosTime = 0
  const fixedDosDate = (40 << 9) | (1 << 5) | 1

  for (const file of [...extensionFiles(extension)].toSorted()) {
    const name = relative(extension, file).split(sep).join("/")
    const nameBytes = Buffer.from(name, "utf8")
    const data = readFileSync(file)
    const checksum = crc32(data)
    const local = localHeader(nameBytes, data, checksum, fixedDosTime, fixedDosDate)
    localParts.push(local, nameBytes, data)

    const central = centralHeader(
      nameBytes,
      data,
      checksum,
      fixedDosTime,
      fixedDosDate,
      localOffset
    )
    centralParts.push(central, nameBytes)
    localOffset += local.length + nameBytes.length + data.length
  }

  return publishArchive(extension, localParts, centralParts, localOffset)
}
