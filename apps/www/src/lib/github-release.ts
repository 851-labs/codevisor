const GITHUB_LATEST_DOWNLOAD_BASE = "https://github.com/851-labs/codevisor/releases/latest/download"

/// GitHub resolves `latest/download` against the latest full stable release,
/// without spending an anonymous API request on every website download. The
/// macOS app ships for Apple silicon only.
export const latestMacOSDownloadURL = (): string =>
  `${GITHUB_LATEST_DOWNLOAD_BASE}/Codevisor-arm64.dmg`
