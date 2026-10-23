import { shellQuote, type EphemeralProvider } from "@codevisor/ephemeral-machines"

export const EPHEMERAL_SERVER_PORT = 49361

export interface EphemeralRemote {
  readonly request: (method: string, path: string, body?: unknown) => Promise<unknown>
  readonly putBytes: (path: string, bytes: Uint8Array) => Promise<void>
}

export class EphemeralRemoteError extends Error {
  override readonly name = "EphemeralRemoteError"
}

const requestTimeoutMs = 5 * 60 * 1000

export const ephemeralRemote = (
  provider: EphemeralProvider,
  providerMachineId: string
): EphemeralRemote => {
  const curl = async (script: string, stdin: string, what: string): Promise<string> => {
    const result = await provider.exec(providerMachineId, {
      script,
      stdin,
      timeoutMs: requestTimeoutMs
    })
    if (result.exitCode !== 0) {
      throw new EphemeralRemoteError(
        `${what} failed on the ephemeral machine: ${result.stderr.trim()}`
      )
    }
    return result.stdout
  }
  return {
    request: async (method, path, body) => {
      const stdout = await curl(
        jsonRequestScript(method, path),
        JSON.stringify(body ?? {}),
        `${method} ${path}`
      )
      return parseResponse(stdout)
    },
    putBytes: async (path, bytes) => {
      await curl(bytesRequestScript(path), Buffer.from(bytes).toString("base64"), `PUT ${path}`)
    }
  }
}

const loopbackUrl = (path: string): string =>
  shellQuote(`http://127.0.0.1:${EPHEMERAL_SERVER_PORT}${path}`)

const jsonRequestScript = (method: string, path: string): string =>
  `curl -sS --fail-with-body -X ${shellQuote(method)} -H 'content-type: application/json' --data-binary @- ${loopbackUrl(path)}`

const bytesRequestScript = (path: string): string =>
  `base64 -d | curl -sS --fail-with-body -X PUT -H 'content-type: application/gzip' --data-binary @- ${loopbackUrl(path)}`

const parseResponse = (stdout: string): unknown => {
  if (stdout.trim() === "") return undefined
  try {
    return JSON.parse(stdout) as unknown
  } catch {
    throw new EphemeralRemoteError(`The ephemeral machine answered with something that isn't JSON`)
  }
}
