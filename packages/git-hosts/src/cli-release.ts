export interface CliPlatform {
  readonly os: NodeJS.Platform
  readonly arch: string
}

export interface CliReleaseSpec {
  readonly command: string
  readonly cliName: string
  readonly releasesUrl: string
  readonly latestUrl: (releasesUrl: string) => string
  readonly assetUrl: (releasesUrl: string, tag: string, name: string) => string
  readonly assetSuffix: (platform: CliPlatform) => string | undefined
  readonly checksumsName: (version: string) => string
  readonly binaryPath: (archiveName: string) => string
}

export const currentPlatform: CliPlatform = { os: process.platform, arch: process.arch }

export const githubCliRelease: CliReleaseSpec = {
  command: "gh",
  cliName: "GitHub CLI",
  releasesUrl: "https://github.com/cli/cli/releases",
  latestUrl: (releasesUrl) => `${releasesUrl}/latest`,
  assetUrl: (releasesUrl, tag, name) => `${releasesUrl}/download/${tag}/${name}`,
  assetSuffix: ({ os, arch }) => {
    const cpu = goArch(arch)
    if (cpu === undefined) return undefined
    if (os === "darwin") return `macOS_${cpu}.zip`
    if (os === "linux") return `linux_${cpu}.tar.gz`
    return undefined
  },
  checksumsName: (version) => `gh_${version}_checksums.txt`,
  binaryPath: (archiveName) => `${archiveName.replace(/\.(?:zip|tar\.gz)$/, "")}/bin/gh`
}

export const gitlabCliRelease: CliReleaseSpec = {
  command: "glab",
  cliName: "GitLab CLI",
  releasesUrl: "https://gitlab.com/gitlab-org/cli/-/releases",
  latestUrl: (releasesUrl) => `${releasesUrl}/permalink/latest`,
  assetUrl: (releasesUrl, tag, name) => `${releasesUrl}/${tag}/downloads/${name}`,
  assetSuffix: ({ os, arch }) => {
    const cpu = goArch(arch)
    if (cpu === undefined) return undefined
    if (os === "darwin" || os === "linux") return `${os}_${cpu}.tar.gz`
    return undefined
  },
  checksumsName: () => "checksums.txt",
  binaryPath: () => "bin/glab"
}

export const archiveName = (spec: CliReleaseSpec, version: string, suffix: string): string =>
  `${spec.command}_${version}_${suffix}`

export const checksumFor = (checksums: string, archive: string): string | undefined =>
  checksums
    .split("\n")
    .map((line) => line.trim().split(/\s+/))
    .find(([, name]) => name === archive)?.[0]
    ?.toLowerCase()

const goArch = (arch: string): string | undefined => {
  if (arch === "arm64") return "arm64"
  if (arch === "x64") return "amd64"
  return undefined
}
