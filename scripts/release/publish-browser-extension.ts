#!/usr/bin/env node

import { readFile } from "node:fs/promises"
import { basename, resolve } from "node:path"
import { pathToFileURL } from "node:url"

export interface ChromeWebStoreConfiguration {
  accessToken: string
  publisherId: string
  extensionId: string
}

// The fields this script reads from the Chrome Web Store API's JSON payloads.
export interface ChromeWebStoreResponse {
  error?: { message?: string }
  rawResponse?: string
  uploadState?: string
  crxVersion?: string
  lastAsyncUploadState?: string
  state?: string
  warningInfo?: { warnings?: unknown[] }
}

export interface WaitForUploadOptions {
  // The Store reports no state at all before an extension's first upload.
  initialState?: string | undefined
  fetchImplementation?: typeof fetch
  intervalMilliseconds?: number
  timeoutMilliseconds?: number
  sleep?: (milliseconds: number) => Promise<unknown>
}

const API_ORIGIN = "https://chromewebstore.googleapis.com"
// The Store omits the upload state entirely before the first upload, so these
// sets are declared over optional values and queried with what it returned.
const SUCCESSFUL_UPLOAD_STATES = new Set<string | undefined>(["SUCCEEDED", "UPLOAD_SUCCEEDED"])
const PENDING_UPLOAD_STATES = new Set<string | undefined>([
  "IN_PROGRESS",
  "UPLOAD_IN_PROGRESS",
  "NOT_FOUND"
])
const FAILED_UPLOAD_STATES = new Set<string | undefined>(["FAILED", "UPLOAD_FAILED"])

const usage = () => {
  console.error(
    "usage: scripts/release/publish-browser-extension.ts <extension.zip> | --publish-only | --status-only"
  )
  console.error()
  console.error("Required environment variables:")
  console.error("  CHROME_WEBSTORE_ACCESS_TOKEN")
  console.error("  CHROME_WEBSTORE_PUBLISHER_ID")
  console.error("  CHROME_WEBSTORE_EXTENSION_ID")
}

const requiredEnvironmentVariable = (
  name: string,
  environment: NodeJS.ProcessEnv = process.env
): string => {
  const value = environment[name]?.trim()
  if (!value) {
    throw new Error(`${name} is required`)
  }
  return value
}

const responseBody = async (response: Response): Promise<ChromeWebStoreResponse> => {
  const text = await response.text()
  if (!text) {
    return {}
  }

  try {
    return JSON.parse(text)
  } catch {
    return { rawResponse: text }
  }
}

const apiRequest = async (
  url: string,
  options: RequestInit,
  fetchImplementation: typeof fetch = fetch
): Promise<ChromeWebStoreResponse> => {
  const response = await fetchImplementation(url, options)
  const body = await responseBody(response)
  if (!response.ok) {
    const details =
      body?.error?.message ??
      body?.rawResponse ??
      `${response.status} ${response.statusText}`.trim()
    throw new Error(`Chrome Web Store API request failed: ${details}`)
  }
  return body
}

const itemName = ({ publisherId, extensionId }: ChromeWebStoreConfiguration): string =>
  `publishers/${encodeURIComponent(publisherId)}/items/${encodeURIComponent(extensionId)}`

export const fetchStatus = async (
  configuration: ChromeWebStoreConfiguration,
  fetchImplementation: typeof fetch = fetch
): Promise<ChromeWebStoreResponse> =>
  apiRequest(
    `${API_ORIGIN}/v2/${itemName(configuration)}:fetchStatus`,
    {
      headers: {
        Authorization: `Bearer ${configuration.accessToken}`
      }
    },
    fetchImplementation
  )

export const waitForUpload = async (
  configuration: ChromeWebStoreConfiguration,
  {
    initialState,
    fetchImplementation = fetch,
    intervalMilliseconds = 5_000,
    timeoutMilliseconds = 5 * 60_000,
    sleep = (milliseconds: number) =>
      new Promise<void>((resolvePromise) => setTimeout(resolvePromise, milliseconds))
  }: WaitForUploadOptions = {}
): Promise<string | undefined> => {
  let state = initialState
  const deadline = Date.now() + timeoutMilliseconds

  while (true) {
    if (SUCCESSFUL_UPLOAD_STATES.has(state)) {
      return state
    }
    if (FAILED_UPLOAD_STATES.has(state)) {
      throw new Error(`Chrome Web Store upload failed with state ${state}`)
    }
    if (!PENDING_UPLOAD_STATES.has(state)) {
      throw new Error(`Chrome Web Store returned an unknown upload state: ${state ?? "(missing)"}`)
    }
    if (Date.now() >= deadline) {
      throw new Error(
        `Timed out waiting for Chrome Web Store upload after ${timeoutMilliseconds}ms`
      )
    }

    await sleep(intervalMilliseconds)
    const status = await fetchStatus(configuration, fetchImplementation)
    state = status.lastAsyncUploadState
    console.log(`Chrome Web Store upload state: ${state}`)
  }
}

export const uploadPackage = async (
  archivePath: string,
  configuration: ChromeWebStoreConfiguration,
  fetchImplementation: typeof fetch = fetch
): Promise<ChromeWebStoreResponse> => {
  const archive = await readFile(archivePath)
  const result = await apiRequest(
    `${API_ORIGIN}/upload/v2/${itemName(configuration)}:upload`,
    {
      method: "POST",
      headers: {
        Authorization: `Bearer ${configuration.accessToken}`,
        "Content-Type": "application/zip"
      },
      body: archive
    },
    fetchImplementation
  )

  console.log(
    `Uploaded ${basename(archivePath)} (${result.crxVersion ?? "version processing"}): ${result.uploadState}`
  )
  return result
}

export const publishItem = async (
  configuration: ChromeWebStoreConfiguration,
  fetchImplementation: typeof fetch = fetch
): Promise<ChromeWebStoreResponse> =>
  apiRequest(
    `${API_ORIGIN}/v2/${itemName(configuration)}:publish`,
    {
      method: "POST",
      headers: {
        Authorization: `Bearer ${configuration.accessToken}`,
        "Content-Type": "application/json"
      },
      body: JSON.stringify({
        publishType: "DEFAULT_PUBLISH",
        blockOnWarnings: true
      })
    },
    fetchImplementation
  )

const reportPublication = (publication: ChromeWebStoreResponse): void => {
  console.log(`Chrome Web Store submission state: ${publication.state}`)
  if (publication.warningInfo?.warnings?.length) {
    console.log(JSON.stringify(publication.warningInfo.warnings, null, 2))
  }
}

export const main = async (
  args: string[] = process.argv.slice(2),
  environment: NodeJS.ProcessEnv = process.env
): Promise<void> => {
  if (args.includes("--help") || args.includes("-h")) {
    usage()
    return
  }

  const statusOnly = args.includes("--status-only")
  const publishOnly = args.includes("--publish-only")
  const positionalArguments = args.filter(
    (argument) => argument !== "--status-only" && argument !== "--publish-only"
  )
  if (
    (statusOnly && publishOnly) ||
    (!statusOnly && !publishOnly && positionalArguments.length !== 1) ||
    ((statusOnly || publishOnly) && positionalArguments.length !== 0)
  ) {
    usage()
    throw new Error("Invalid arguments")
  }

  const configuration = {
    accessToken: requiredEnvironmentVariable("CHROME_WEBSTORE_ACCESS_TOKEN", environment),
    publisherId: requiredEnvironmentVariable("CHROME_WEBSTORE_PUBLISHER_ID", environment),
    extensionId: requiredEnvironmentVariable("CHROME_WEBSTORE_EXTENSION_ID", environment)
  }

  if (statusOnly) {
    const status = await fetchStatus(configuration)
    console.log(JSON.stringify(status, null, 2))
    return
  }

  if (publishOnly) {
    reportPublication(await publishItem(configuration))
    return
  }

  // The argument checks above leave exactly one positional argument here.
  const archivePath = resolve(positionalArguments[0]!)
  const upload = await uploadPackage(archivePath, configuration)
  await waitForUpload(configuration, { initialState: upload.uploadState })

  const publication = await publishItem(configuration)
  reportPublication(publication)
}

// Node always supplies the entry script path in argv[1].
if (import.meta.url === pathToFileURL(process.argv[1]!).href) {
  main().catch((error) => {
    console.error(error instanceof Error ? error.message : error)
    process.exitCode = 1
  })
}
