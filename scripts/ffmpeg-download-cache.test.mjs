import assert from "node:assert/strict"
import { execFile } from "node:child_process"
import { once } from "node:events"
import { cp, mkdtemp, readdir, readFile, rm, symlink, writeFile } from "node:fs/promises"
import { createServer } from "node:http"
import { createRequire } from "node:module"
import { tmpdir } from "node:os"
import { dirname, join } from "node:path"
import { test } from "node:test"
import { promisify } from "node:util"
import { gzipSync } from "node:zlib"

const execute = promisify(execFile)
const require = createRequire(new URL("../apps/server/package.json", import.meta.url))
const packageDirectory = dirname(require.resolve("ffmpeg-static/package.json"))

for (const hostname of [
  "release-assets.githubusercontent.com",
  "github-production-release-asset-2e65be.s3.amazonaws.com",
  "mirror.example.com"
]) {
  test(`FFmpeg installs cache release downloads from ${hostname}`, async () => {
    const fixture = await mkdtemp(join(tmpdir(), "codevisor-ffmpeg-cache-"))
    const cacheDirectory = join(fixture, "cache")
    const preload = join(fixture, "preload.cjs")
    let redirects = 0
    let downloads = 0
    const server = createServer((request, response) => {
      const url = new URL(request.url, "https://github.com")
      if (url.pathname.startsWith("/eugeneware/ffmpeg-static/releases/download/")) {
        redirects += 1
        const [, version, filename] = url.pathname.match(/\/download\/([^/]+)\/([^/]+)$/)
        const signature = hostname.endsWith(".s3.amazonaws.com")
          ? `X-Amz-Signature=${redirects}`
          : `sig=${redirects}&se=${redirects}&jwt=${redirects}`
        response.writeHead(302, {
          location: `https://${hostname}/29458513/${version}/${filename}?${signature}`,
          "cache-control": "no-store"
        })
        response.end()
        return
      }
      downloads += 1
      const body = Buffer.from(`asset:${url.pathname}`)
      const encoded = url.pathname.endsWith(".gz") ? gzipSync(body) : body
      response.writeHead(200, {
        "content-length": encoded.length,
        "cache-control": "public, max-age=31536000"
      })
      response.end(encoded)
    })
    try {
      server.listen(0, "127.0.0.1")
      await once(server, "listening")
      await writeFile(
        preload,
        `const http = require("node:http")
const https = require("node:https")
const Module = require("node:module")
const load = Module._load
Module._load = function (id, ...args) {
  if (id === "env-paths") return () => ({ cache: process.env.FFMPEG_TEST_CACHE })
  return load.call(this, id, ...args)
}
https.request = (options, callback) => http.request({
  ...options,
  protocol: "http:",
  hostname: "127.0.0.1",
  host: "127.0.0.1",
  port: Number(process.env.FFMPEG_TEST_PORT)
}, callback)
`
      )
      const install = async (name, version) => {
        const directory = join(fixture, name)
        await cp(packageDirectory, directory, {
          recursive: true,
          filter: (path) => !["ffmpeg", "ffmpeg.exe"].includes(path.split(/[\\/]/).at(-1))
        })
        await symlink(dirname(packageDirectory), join(directory, "node_modules"), "dir")
        await execute(process.execPath, ["--require", preload, join(directory, "install.js")], {
          timeout: 15_000,
          env: {
            ...process.env,
            CI: "1",
            HTTPS_PROXY: "",
            https_proxy: "",
            HTTP_PROXY: "",
            http_proxy: "",
            FFMPEG_TEST_CACHE: cacheDirectory,
            FFMPEG_TEST_PORT: String(server.address().port),
            FFMPEG_BINARY_RELEASE: version,
            npm_config_platform: "darwin",
            npm_config_arch: "arm64"
          }
        })
        assert.equal(
          await readFile(join(directory, "ffmpeg"), "utf8"),
          `asset:/29458513/${version}/ffmpeg-darwin-arm64.gz`
        )
      }

      await install("first", "release-one")
      assert.equal(downloads, 3)
      await install("second", "release-one")
      const stableKeys = hostname !== "mirror.example.com"
      assert.equal(downloads, stableKeys ? 3 : 6)
      assert.equal(redirects, 6)
      const entries = await readdir(cacheDirectory)
      assert.equal(entries.filter((name) => name.endsWith(".body")).length, stableKeys ? 3 : 6)

      await install("new-version", "release-two")
      assert.equal(downloads, stableKeys ? 6 : 9)
    } finally {
      await new Promise((resolve) => server.close(resolve))
      await rm(fixture, { recursive: true, force: true })
    }
  })
}
