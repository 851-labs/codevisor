import { describe, expect, it } from "vitest"

import { imageDiskBytes, isRegistryImage } from "./oci-manifest.js"

const chunk = 512 * 1024 * 1024
const zeroDigest = "sha256:zero"
const diskLayer = (digest: string, size = 3_000_000) => ({
  mediaType: "application/vnd.cirruslabs.tart.disk.v2",
  size,
  annotations: {
    "org.cirruslabs.tart.uncompressed-size": String(chunk),
    "org.cirruslabs.tart.uncompressed-content-digest": digest
  }
})
const manifest = {
  layers: [
    { mediaType: "application/vnd.cirruslabs.tart.config.v1", size: 509 },
    diskLayer("sha256:a", 200_000_000),
    diskLayer(zeroDigest),
    diskLayer("sha256:b", 150_000_000),
    diskLayer(zeroDigest),
    { mediaType: "application/vnd.cirruslabs.tart.nvram.v1", size: 70_000 }
  ]
}

const offline = () => Promise.reject(new Error("offline"))
const noRealm = () => Promise.resolve(new Response("", { status: 401 }))
const missing = () => Promise.resolve(new Response("", { status: 404 }))
const reply = (layers: ReadonlyArray<object>) => () => Promise.resolve(Response.json({ layers }))

const registry = () => {
  const requests: string[] = []
  const fetchFn = (url: string, headers: Readonly<Record<string, string>>) => {
    requests.push(`${url} ${headers["authorization"] ?? "anonymous"}`)
    if (url.startsWith("https://ghcr.io/token")) {
      return Promise.resolve(Response.json({ token: "t0k" }))
    }
    if (headers["authorization"] !== "Bearer t0k") {
      return Promise.resolve(
        new Response("", {
          status: 401,
          headers: {
            "www-authenticate":
              'Bearer realm="https://ghcr.io/token",service="ghcr.io",scope="repository:cirruslabs/ubuntu:pull"'
          }
        })
      )
    }
    return Promise.resolve(Response.json(manifest))
  }
  return { requests, fetchFn }
}

describe("Tart image sizes from the registry", () => {
  it("counts the disk chunks an image really stores, signing in anonymously first", async () => {
    const { requests, fetchFn } = registry()

    const bytes = await imageDiskBytes("ghcr.io/cirruslabs/ubuntu:latest", fetchFn)

    expect(bytes).toBe(2 * chunk)
    expect(requests).toEqual([
      "https://ghcr.io/v2/cirruslabs/ubuntu/manifests/latest anonymous",
      "https://ghcr.io/token?service=ghcr.io&scope=repository%3Acirruslabs%2Fubuntu%3Apull anonymous",
      "https://ghcr.io/v2/cirruslabs/ubuntu/manifests/latest Bearer t0k"
    ])
  })

  it("knows registry images from local VMs, and gives up quietly when the registry can't answer", async () => {
    expect(isRegistryImage("ghcr.io/cirruslabs/macos-tahoe-base:latest")).toBe(true)
    expect(isRegistryImage("codevisor-image-0123456789abcdef")).toBe(false)
    expect(await imageDiskBytes("codevisor-image-0123456789abcdef", offline)).toBeUndefined()
    expect(await imageDiskBytes("ghcr.io/cirruslabs/ubuntu:latest", offline)).toBeUndefined()
  })

  it("reads the manifest a ref points at, by tag, digest or the latest tag", async () => {
    const asked: string[] = []
    const open = (url: string) => {
      asked.push(url)
      return Promise.resolve(Response.json(manifest))
    }

    for (const image of [
      "localhost:5000/team/vm:2.0",
      "ghcr.io/cirruslabs/ubuntu",
      "ghcr.io/cirruslabs/ubuntu@sha256:abc",
      "localhost/vm:1"
    ]) {
      await imageDiskBytes(image, open)
    }

    expect(isRegistryImage("cirruslabs/ubuntu:latest")).toBe(false)
    expect(asked).toEqual([
      "https://localhost:5000/v2/team/vm/manifests/2.0",
      "https://ghcr.io/v2/cirruslabs/ubuntu/manifests/latest",
      "https://ghcr.io/v2/cirruslabs/ubuntu/manifests/sha256:abc",
      "https://localhost/v2/vm/manifests/1"
    ])
  })

  it("accepts an access_token, and gives up when a sign-in step or the manifest fails", async () => {
    const challenge = { "www-authenticate": 'Bearer realm="https://r.example/token"' }
    const signIn =
      (tokenReply: () => Response) => (url: string, headers: Readonly<Record<string, string>>) => {
        if (url.startsWith("https://r.example/token")) return Promise.resolve(tokenReply())
        if (headers["authorization"] === undefined) {
          return Promise.resolve(new Response("", { status: 401, headers: challenge }))
        }
        return Promise.resolve(Response.json(manifest))
      }
    const image = "r.example/team/vm:1"

    expect(
      await imageDiskBytes(
        image,
        signIn(() => Response.json({ access_token: "a" }))
      )
    ).toBe(2 * chunk)
    expect(
      await imageDiskBytes(
        image,
        signIn(() => Response.json({}))
      )
    ).toBeUndefined()
    expect(await imageDiskBytes(image, noRealm)).toBeUndefined()
    expect(await imageDiskBytes(image, missing)).toBeUndefined()
  })

  it("falls back to the download size without Tart's annotations, and knows nothing without a disk", async () => {
    const plainDisk = { mediaType: "application/vnd.cirruslabs.tart.disk.v1", size: 1234 }
    const config = { mediaType: "application/vnd.oci.image.config.v1+json", size: 10 }

    expect(await imageDiskBytes("ghcr.io/a/b:1", reply([config, plainDisk]))).toBe(1234)
    expect(await imageDiskBytes("ghcr.io/a/b:1", reply([config]))).toBeUndefined()
  })
})
