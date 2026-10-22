import { existsSync, readdirSync, realpathSync } from "node:fs"
import { join } from "node:path"

import { describe, expect, it } from "vitest"

import { CliInstallError } from "./cli-install.js"
import type { CliPlatform } from "./cli-release.js"
import { githubHost } from "./github-host.js"
import { gitlabHost } from "./gitlab-host.js"
import {
  emptyEnv,
  fakeArchive,
  fakeCli,
  sha256Of,
  startReleaseServer,
  testTempDir,
  versionScript,
  type FakeArchive,
  type ReleaseRoute
} from "./test-support.js"

const linux: CliPlatform = { os: "linux", arch: "x64" }
const releases = "/cli/cli/releases"

const ghArchive = (version: string, script = versionScript(`gh version ${version} (2026-10-01)`)) =>
  fakeArchive(`gh_${version}_linux_amd64.tar.gz`, `gh_${version}_linux_amd64/bin/gh`, script)

const ghRoutes = (
  version: string,
  archive: FakeArchive,
  checksums = `${archive.sha256}  ${archive.name}\nfeed  gh_${version}_linux_arm64.tar.gz\n`
): Record<string, ReleaseRoute> => ({
  [`${releases}/latest`]: { redirect: `${releases}/tag/v${version}` },
  [`${releases}/tag/v${version}`]: { body: "release page" },
  [`${releases}/download/v${version}/gh_${version}_checksums.txt`]: { body: checksums },
  [`${releases}/download/v${version}/${archive.name}`]: { body: archive.bytes }
})

const githubWith = async (routes: Record<string, ReleaseRoute>, platform = linux) => {
  const server = await startReleaseServer(routes)
  const toolsDir = join(testTempDir("codevisor-tools-"), "tools")
  const host = githubHost({ toolsDir, platform, releasesUrl: `${server.url}${releases}` })
  return { host, server, toolsDir }
}

const installFailure = async (install: Promise<unknown>): Promise<string> => {
  const failure = await install.catch((cause: unknown) => cause)
  if (!(failure instanceof CliInstallError)) throw new Error("Expected the install to fail")
  return failure.message
}

describe("installing a git host CLI", () => {
  it("installs gh's release binary into the tools directory once its checksum matches", async () => {
    const { host, toolsDir } = await githubWith(ghRoutes("9.1.0", ghArchive("9.1.0")))
    const env = emptyEnv()

    expect(await host.detect(env)).toBeUndefined()
    const installed = await host.install(env)

    expect(installed).toEqual({ path: join(toolsDir, "bin", "gh"), version: "9.1.0" })
    expect(await host.detect(env)).toEqual(installed)
    expect(realpathSync(installed.path)).toBe(
      realpathSync(join(toolsDir, "gh", "9.1.0", "gh_9.1.0_linux_amd64", "bin", "gh"))
    )
    expect(readdirSync(toolsDir).toSorted()).toEqual(["bin", "gh"])
    expect(readdirSync(join(toolsDir, "bin"))).toEqual(["gh"])
  })

  it("keeps a gh that's already on PATH ahead of the installed one", async () => {
    const { host } = await githubWith(ghRoutes("9.1.0", ghArchive("9.1.0")))
    const own = fakeCli("gh", versionScript("gh version 2.98.0 (2026-08-20)"))

    await host.install(emptyEnv())

    expect(await host.detect(own.env)).toEqual({ path: own.path, version: "2.98.0" })
  })

  it("replaces an older install and drops its files", async () => {
    const routes = ghRoutes("9.1.0", ghArchive("9.1.0"))
    const { host, toolsDir } = await githubWith(routes)
    await host.install(emptyEnv())

    Object.assign(routes, ghRoutes("9.2.0", ghArchive("9.2.0")))
    const updated = await host.install(emptyEnv())

    expect(updated.version).toBe("9.2.0")
    expect(readdirSync(join(toolsDir, "gh"))).toEqual(["9.2.0"])
  })

  it("shares one download between sign-ins that install at the same time", async () => {
    const archive = ghArchive("9.1.0")
    const { host, server } = await githubWith(ghRoutes("9.1.0", archive))

    const [first, second] = await Promise.all([host.install(emptyEnv()), host.install(emptyEnv())])

    expect(first).toEqual(second)
    expect(server.requests.filter((path) => path.endsWith(archive.name))).toHaveLength(1)
  })

  it("refuses a download that doesn't match the release's checksum", async () => {
    const archive = ghArchive("9.1.0")
    const wrong = `${"0".repeat(64)}  ${archive.name}\n`
    const { host, toolsDir } = await githubWith(ghRoutes("9.1.0", archive, wrong))

    expect(await installFailure(host.install(emptyEnv()))).toBe(
      "The GitHub CLI download didn't match its checksum."
    )
    expect(existsSync(toolsDir)).toBe(false)
  })

  it("refuses a release that lists no checksum for this machine", async () => {
    const archive = ghArchive("9.1.0")
    const { host, server } = await githubWith(
      ghRoutes("9.1.0", archive, "feed  gh_9.1.0_linux_arm64.tar.gz\n")
    )

    expect(await installFailure(host.install(emptyEnv()))).toBe(
      "GitHub CLI 9.1.0 has no checksum for this machine."
    )
    expect(server.requests.some((path) => path.endsWith(archive.name))).toBe(false)
  })

  it("explains downloads that fail, break off, or can't connect", async () => {
    const archive = ghArchive("9.1.0")
    const routes = ghRoutes("9.1.0", archive)
    const missing = await githubWith({
      ...routes,
      [`${releases}/download/v9.1.0/${archive.name}`]: { status: 404 }
    })
    const brokenChecksums = await githubWith({
      ...routes,
      [`${releases}/download/v9.1.0/gh_9.1.0_checksums.txt`]: { cutOff: true }
    })
    const brokenArchive = await githubWith({
      ...routes,
      [`${releases}/download/v9.1.0/${archive.name}`]: { cutOff: true }
    })
    const unreachable = githubHost({
      toolsDir: testTempDir("codevisor-tools-"),
      platform: linux,
      releasesUrl: "http://127.0.0.1:9/cli/cli/releases"
    })
    const offline = "Couldn't download GitHub CLI. Check this machine's internet connection."

    expect(await installFailure(missing.host.install(emptyEnv()))).toBe(
      "Couldn't download GitHub CLI (HTTP 404)."
    )
    expect(await installFailure(brokenChecksums.host.install(emptyEnv()))).toBe(offline)
    expect(await installFailure(brokenArchive.host.install(emptyEnv()))).toBe(offline)
    expect(await installFailure(unreachable.install(emptyEnv()))).toBe(offline)
  })

  it("explains a latest release it can't read", async () => {
    const { host } = await githubWith({
      [`${releases}/latest`]: { redirect: `${releases}/tag/nightly` },
      [`${releases}/tag/nightly`]: { body: "nightly" }
    })

    expect(await installFailure(host.install(emptyEnv()))).toBe(
      "Couldn't find the latest GitHub CLI release."
    )
  })

  it("explains an archive it can't unpack or a binary that doesn't run", async () => {
    const garbage = Buffer.from("not a tarball")
    const unpackable = await githubWith(
      ghRoutes("9.1.0", {
        name: "gh_9.1.0_linux_amd64.tar.gz",
        bytes: garbage,
        sha256: sha256Of(garbage)
      })
    )
    const broken = await githubWith(ghRoutes("9.1.0", ghArchive("9.1.0", "exit 1")))

    expect(await installFailure(unpackable.host.install(emptyEnv()))).toBe(
      "Couldn't unpack the GitHub CLI download."
    )
    expect(await installFailure(broken.host.install(emptyEnv()))).toBe(
      "GitHub CLI was installed but doesn't run."
    )
  })

  it("won't install on an unknown platform or a server without a tools directory", async () => {
    const { server } = await githubWith({})
    const windows = githubHost({
      toolsDir: testTempDir("codevisor-tools-"),
      platform: { os: "win32", arch: "x64" },
      releasesUrl: server.url
    })
    const ia32 = githubHost({
      toolsDir: testTempDir("codevisor-tools-"),
      platform: { os: "linux", arch: "ia32" },
      releasesUrl: server.url
    })
    const pathOnly = githubHost({ platform: linux, releasesUrl: server.url })

    expect(await installFailure(windows.install(emptyEnv()))).toBe(
      "GitHub CLI can't be installed on win32 x64."
    )
    expect(await installFailure(ia32.install(emptyEnv()))).toBe(
      "GitHub CLI can't be installed on linux ia32."
    )
    expect(await installFailure(pathOnly.install(emptyEnv()))).toBe(
      "gh isn't installed on this machine"
    )
    expect(server.requests).toEqual([])
  })

  it.runIf(process.platform === "darwin")("unpacks gh's macOS zip", async () => {
    const archive = fakeArchive(
      "gh_9.1.0_macOS_arm64.zip",
      "gh_9.1.0_macOS_arm64/bin/gh",
      versionScript("gh version 9.1.0 (2026-10-01)"),
      "zip"
    )
    const { host } = await githubWith(ghRoutes("9.1.0", archive), { os: "darwin", arch: "arm64" })

    expect(await host.install(emptyEnv())).toMatchObject({ version: "9.1.0" })
  })

  it("installs glab from GitLab's release downloads", async () => {
    const archive = fakeArchive(
      "glab_1.124.0_darwin_amd64.tar.gz",
      "bin/glab",
      versionScript("glab 1.124.0 (abc123)")
    )
    const glabReleases = "/gitlab-org/cli/-/releases"
    const server = await startReleaseServer({
      [`${glabReleases}/permalink/latest`]: { redirect: `${glabReleases}/v1.124.0` },
      [`${glabReleases}/v1.124.0`]: { body: "release page" },
      [`${glabReleases}/v1.124.0/downloads/checksums.txt`]: {
        body: `${archive.sha256}  ${archive.name}\n`
      },
      [`${glabReleases}/v1.124.0/downloads/${archive.name}`]: { body: archive.bytes }
    })
    const toolsDir = testTempDir("codevisor-tools-")
    const glab = gitlabHost({
      toolsDir,
      platform: { os: "darwin", arch: "x64" },
      releasesUrl: `${server.url}${glabReleases}`
    })

    expect(await glab.install(emptyEnv())).toEqual({
      path: join(toolsDir, "bin", "glab"),
      version: "1.124.0"
    })
  })
})
