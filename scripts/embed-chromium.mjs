import { createHash } from "node:crypto"
import { cp, mkdir, readFile, readdir, realpath, rm, symlink, writeFile } from "node:fs/promises"
import { join, resolve } from "node:path"
import { fileURLToPath } from "node:url"

import { cloneTree, ensureStoreEntry, touchStoreEntry } from "./apfs-clone.mjs"
import {
  chromiumArtifactsRoot,
  chromiumHelperName,
  chromiumHelperSuffixes,
  run
} from "./chromium-artifact.mjs"

const root = resolve(fileURLToPath(new URL("..", import.meta.url)))
const env = process.env
const architectures = env.ARCHS.trim().split(/\s+/)
const frameworks = join(env.TARGET_BUILD_DIR, env.FRAMEWORKS_FOLDER_PATH)
const source = join(root, "apps/macos/Frameworks/Chromium")
const name = "Chromium Embedded Framework.framework"
const framework = join(frameworks, name)
await mkdir(frameworks, { recursive: true })
const signing = env.EXPANDED_CODE_SIGN_IDENTITY || "-"

function plistStringEntries(strings) {
  return Object.entries(strings)
    .map(
      ([key, value]) =>
        `<key>${key}</key><string>${value.replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;")}</string>`
    )
    .join("")
}

function devToolsResourceIndex(resourceHeader) {
  const devToolsSection = resourceHeader
    .split("// From devtools_resources.h:")[1]
    ?.split("// From ")[0]
  if (!devToolsSection) throw new Error("CEF SDK is missing its DevTools resource index")
  const devToolsResources = Object.fromEntries(
    [...devToolsSection.matchAll(/^#define (\w+) (\d+)$/gm)].map(([, resourceName, id]) => [
      resourceName,
      Number(id)
    ])
  )
  if (!devToolsResources.ENTRYPOINTS_DEVTOOLS_APP_DEVTOOLS_APP_JS)
    throw new Error("CEF SDK is missing the inspector frontend")
  return devToolsResources
}

async function* files(directory, relative = "") {
  for (const entry of await readdir(join(directory, relative), { withFileTypes: true })) {
    const path = join(relative, entry.name)
    if (entry.isDirectory()) yield* files(directory, path)
    else if (entry.isFile()) yield path
  }
}

async function assembleFramework(destination) {
  const versioned = join(destination, "Versions/A")
  await mkdir(versioned, { recursive: true })
  await run(
    "rsync",
    ["-a", join(source, architectures[0], "sdk/Release", name) + "/", versioned + "/"],
    root
  )
  await symlink("A", join(destination, "Versions/Current"))
  for (const item of ["Chromium Embedded Framework", "Libraries", "Resources"]) {
    await symlink(`Versions/Current/${item}`, join(destination, item))
  }
  const binaries = []
  for await (const path of files(destination)) {
    if (path.endsWith("Chromium Embedded Framework") || path.endsWith(".dylib")) binaries.push(path)
  }
  if (architectures.length > 1) {
    for (const path of binaries) {
      await run(
        "lipo",
        [
          "-create",
          ...architectures.map((arch) =>
            join(source, arch, "sdk/Release", name, path.replace(/^Versions\/A\//, ""))
          ),
          "-output",
          join(destination, path)
        ],
        root
      )
    }
    for (const arch of architectures.slice(1)) {
      await cp(
        join(source, arch, "sdk/Release", name, `Resources/v8_context_snapshot.${arch}.bin`),
        join(destination, `Resources/v8_context_snapshot.${arch}.bin`)
      )
    }
  }
  for (const path of binaries)
    await run(
      "codesign",
      [
        "--force",
        "--sign",
        signing,
        "--options",
        "runtime",
        "--timestamp=none",
        join(destination, path)
      ],
      root
    )
  await run(
    "codesign",
    ["--force", "--sign", signing, "--options", "runtime", "--timestamp=none", destination],
    root
  )
}

async function signedFrameworkKey() {
  const hash = createHash("sha256")
  for (const arch of architectures) {
    hash.update(`${arch}\0${await realpath(join(source, arch, "sdk/Release", name))}\0`)
  }
  hash.update(`${signing}\0`)
  hash.update(await readFile(fileURLToPath(import.meta.url)))
  return hash.digest("hex").slice(0, 32)
}

await rm(framework, { recursive: true, force: true })
if (env.CONFIGURATION === "Debug") {
  const store = join(chromiumArtifactsRoot(env), "signed-frameworks")
  const key = await signedFrameworkKey()
  const entry = await ensureStoreEntry(store, key, (staging) =>
    assembleFramework(join(staging, name))
  )
  await touchStoreEntry(store, key)
  await cloneTree(join(entry, name), framework)
} else {
  await assembleFramework(framework)
}

const storageName = "CodevisorBrowserStorage.dylib"
const storageLibrary = join(frameworks, storageName)
if (architectures.length === 1)
  await cp(join(source, architectures[0], storageName), storageLibrary)
else
  await run(
    "lipo",
    [
      "-create",
      ...architectures.map((arch) => join(source, arch, storageName)),
      "-output",
      storageLibrary
    ],
    root
  )
await run(
  "codesign",
  ["--force", "--sign", signing, "--options", "runtime", "--timestamp=none", storageLibrary],
  root
)
for (const suffix of chromiumHelperSuffixes) {
  const helperName = `${chromiumHelperName(env.PRODUCT_NAME)}${suffix}`
  const bundle = join(frameworks, `${helperName}.app`)
  await rm(join(frameworks, `Codevisor Helper${suffix}.app`), { recursive: true, force: true })
  await rm(bundle, { recursive: true, force: true })
  const contents = join(bundle, "Contents")
  await mkdir(join(contents, "MacOS"), { recursive: true })
  const executable = join(contents, "MacOS", helperName)
  if (architectures.length === 1)
    await cp(join(source, architectures[0], "Codevisor Helper"), executable)
  else
    await run(
      "lipo",
      [
        "-create",
        ...architectures.map((arch) => join(source, arch, "Codevisor Helper")),
        "-output",
        executable
      ],
      root
    )
  const identifier = `${env.PRODUCT_BUNDLE_IDENTIFIER}.chromium.helper${suffix ? "." + suffix.slice(2, -1).toLowerCase() : ""}`
  const strings = {
    CFBundleExecutable: helperName,
    CFBundleName: helperName,
    CFBundleDisplayName: helperName,
    CFBundleIconFile: "AppIcon.icns",
    CFBundleIdentifier: identifier,
    CFBundlePackageType: "APPL",
    CFBundleVersion: "1",
    CFBundleShortVersionString: "1.0",
    LSMinimumSystemVersion: "12.0"
  }
  await writeFile(
    join(contents, "Info.plist"),
    `<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0"><dict>${plistStringEntries(strings)}<key>LSUIElement</key><true/><key>LSEnvironment</key><dict><key>MallocNanoZone</key><string>0</string></dict></dict></plist>`
  )
}
const resources = join(env.TARGET_BUILD_DIR, env.UNLOCALIZED_RESOURCES_FOLDER_PATH)
await mkdir(resources, { recursive: true })
const resourceHeader = await readFile(
  join(source, architectures[0], "sdk/include/cef_pack_resources.h"),
  "utf8"
)
const devToolsResources = devToolsResourceIndex(resourceHeader)
await writeFile(
  join(resources, "Chromium-DevTools-resources.json"),
  JSON.stringify(devToolsResources)
)
await cp(
  join(root, "apps/macos/ChromiumHelper/devtools.js"),
  join(resources, "Chromium-DevTools.js")
)
for (const [sourceName, targetName] of [
  ["LICENSE.txt", "Chromium-LICENSE.txt"],
  ["CREDITS.html", "Chromium-CREDITS.html"]
]) {
  await rm(join(frameworks, targetName), { force: true })
  await cp(join(source, architectures[0], "sdk", sourceName), join(resources, targetName))
}
