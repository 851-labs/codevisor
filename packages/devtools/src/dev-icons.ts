import { cp, mkdir, readFile, rm, writeFile } from "node:fs/promises"
import { join } from "node:path"

import type { InstanceColor } from "./color.ts"
import type { CommandRunner } from "./commands.ts"
import type { DevelopmentLayout } from "./dev-layout.ts"

export interface BrowserExtensionIconSource {
  readonly appName: string
  readonly derivedDataPath: string
  readonly layout: DevelopmentLayout
  readonly run: CommandRunner["run"]
}

export async function createDevelopmentAppIcon(
  repoRoot: string,
  developmentIconColor: InstanceColor,
  platform = "macos"
): Promise<string> {
  const template = join(repoRoot, "apps", "macos", "Codevisor", "Resources", "AppIconDev.icon")
  const generated = join(
    repoRoot,
    "apps",
    platform,
    "Codevisor",
    "Resources",
    "AppIconDevGenerated.icon"
  )
  await rm(generated, { recursive: true, force: true })
  await mkdir(join(generated, "Assets"), { recursive: true })
  const manifest = JSON.parse(await readFile(join(template, "icon.json"), "utf8"))
  manifest.fill = { "automatic-gradient": developmentIconColor.composer }
  await writeFile(join(generated, "icon.json"), `${JSON.stringify(manifest, null, 2)}\n`)
  await cp(join(template, "Assets", "icon-v2.svg"), join(generated, "Assets", "icon-v2.svg"))
  return generated
}

export async function createDevelopmentBrowserExtensionIcons(
  source: BrowserExtensionIconSource
): Promise<string> {
  const iconset = join(source.layout.build.generated, "BrowserExtensionDev.iconset")
  const compiledIcon = join(
    source.derivedDataPath,
    "Build",
    "Products",
    "Debug",
    `${source.appName}.app`,
    "Contents",
    "Resources",
    "AppIconDevGenerated.icns"
  )
  await rm(iconset, { recursive: true, force: true })
  await source.run("iconutil", ["--convert", "iconset", "--output", iconset, compiledIcon])
  return iconset
}
