import { execFile } from "node:child_process"
import { randomUUID } from "node:crypto"
import { createServer } from "node:http"
import { promisify } from "node:util"
import { copyFile, mkdir, mkdtemp, open, readFile, writeFile } from "node:fs/promises"
import { join } from "node:path"
import { developmentLayout } from "./dev-layout.mjs"
import { runXcodebuild } from "./xcodebuild.mjs"
import { gallery, pngDimensions, screenshotAttachments } from "./screenshots-lib.mjs"

const execute = promisify(execFile)

// Both platforms use isolated builds, identical attachment validation, and the
// same gallery/manifest format. Only device setup and Xcode arguments differ.
export async function createCapture(root, platform, options) {
  await mkdir(options.output, { recursive: true })
  const output = await mkdtemp(join(options.output, "capture-"))
  const layout = developmentLayout(root)
  layout.build[platform] = {
    derivedData: join(root, `tmp/build/${platform}-screenshots/DerivedData`),
    sourcePackages: join(root, `tmp/build/${platform}-screenshots/SourcePackages`)
  }
  const images = []
  const command = async (program, args) =>
    (await execute(program, args, { cwd: root, maxBuffer: 16 * 1024 * 1024 })).stdout.trim()

  async function build(args, logfile, appearance = "light") {
    const log = await open(join(output, logfile), "w")
    const capture =
      platform === "macos" && args.includes("test-without-building")
        ? await captureMacWindows(join(output, `${appearance}-window-captures`))
        : undefined
    try {
      await runXcodebuild(root, platform, ["-jobs", "4", ...args], {
        layout,
        environment: {
          ...process.env,
          TEST_RUNNER_CODEVISOR_CAPTURE_SCREENSHOTS: "1",
          TEST_RUNNER_CODEVISOR_SCREENSHOT_BUNDLE_IDENTIFIER: options.bundleIdentifier ?? "",
          TEST_RUNNER_CODEVISOR_SCREENSHOT_CAPTURE_URL: capture?.url ?? "",
          TEST_RUNNER_CODEVISOR_SCREENSHOT_APPEARANCE: appearance
        },
        stdio: ["ignore", log.fd, log.fd]
      })
    } catch (error) {
      throw new Error(`${error.message}. See ${join(output, logfile)}`, { cause: error })
    } finally {
      await capture?.stop()
      await log.close()
    }
  }

  async function exportImages(result, key, device, appearance) {
    const exports = join(output, `${key}-${appearance}-attachments`)
    await command("xcrun", [
      "xcresulttool",
      "export",
      "attachments",
      "--path",
      result,
      "--output-path",
      exports
    ])
    const attachments = screenshotAttachments(
      JSON.parse(await readFile(join(exports, "manifest.json"), "utf8"))
    )
    await mkdir(join(output, key, appearance), { recursive: true })
    for (const { scene, filename } of attachments) {
      const source = join(exports, filename)
      const dimensions = pngDimensions(await readFile(source), device)
      const file = `${key}/${appearance}/${scene}-${key}-${appearance}.png`
      await copyFile(source, join(output, file))
      images.push({
        platform,
        device: key,
        model: device.name,
        scene,
        appearance,
        file,
        ...dimensions
      })
    }
  }

  async function finish(metadata) {
    const manifest = {
      sourceCommit: await command("git", ["rev-parse", "HEAD"]),
      workingTreeChanged: (await command("git", ["status", "--porcelain"])).length > 0,
      ...metadata,
      images
    }
    await writeFile(join(output, "manifest.json"), `${JSON.stringify(manifest, null, 2)}\n`)
    await writeFile(join(output, "index.html"), gallery(images))
    await execute(
      "zip",
      ["-q", "screenshots.zip", "manifest.json", "index.html", ...images.map(({ file }) => file)],
      {
        cwd: output
      }
    )
    console.log(`Saved ${images.length} screenshots. Gallery: ${join(output, "index.html")}`)
    console.log(`Zip: ${join(output, "screenshots.zip")}`)
  }
  console.log(`Screenshots: ${output}`)
  return { output, command, build, exportImages, finish }
}

// Keep screen-recording permission on the invoking terminal, instead of on a
// newly signed XCTest runner. XCTest requests capture only after checking the UI.
async function captureMacWindows(directory) {
  await mkdir(directory, { recursive: true })
  const path = `/${randomUUID()}`
  const server = createServer(async (request, response) => {
    if (request.method !== "POST" || request.url !== path) {
      response.writeHead(404).end()
      return
    }
    try {
      let body = ""
      for await (const chunk of request) {
        body += chunk
        if (body.length > 1024) throw new Error("Capture request is too large")
      }
      const { windowId } = JSON.parse(body)
      if (!Number.isSafeInteger(windowId) || windowId <= 0) throw new Error("Invalid window ID")
      const file = join(directory, `${randomUUID()}.png`)
      await execute("/usr/sbin/screencapture", ["-x", "-o", "-l", String(windowId), file])
      response.writeHead(200, { "Content-Type": "image/png" }).end(await readFile(file))
    } catch (error) {
      response.writeHead(500, { "Content-Type": "text/plain" }).end(error.message)
    }
  })
  await new Promise((resolve, reject) => {
    server.once("error", reject)
    server.listen(0, "127.0.0.1", resolve)
  })
  return {
    url: `http://127.0.0.1:${server.address().port}${path}`,
    stop() {
      return new Promise((resolve, reject) =>
        server.close((error) => (error ? reject(error) : resolve()))
      )
    }
  }
}
