import type { IncomingMessage, ServerResponse } from "node:http"

import {
  SimulatorCreateDevice,
  SimulatorDeviceAction,
  SimulatorRenameDevice,
  SimulatorSettingsChange
} from "@codevisor/api"

import {
  HttpFailure,
  readSchema,
  writeJson,
  type CodevisorServerConfig
} from "../server-context.js"
import { SimulatorCommandError, SimulatorRequestError, type Simulators } from "../simulators.js"

/// Whether this machine offers Simulator panes: Xcode's simulators work and
/// the native app is running to stream them.
export const simulatorsAvailable = async (config: CodevisorServerConfig): Promise<boolean> =>
  config.simulators !== undefined &&
  config.screenSharing !== undefined &&
  (await config.simulators.available())

/// `/v1/simulators/*`: the device list, device types and chrome, and simctl
/// actions. Video and input go through `/v1/screen-sharing`.
export const routeSimulators = async (
  config: CodevisorServerConfig,
  request: IncomingMessage,
  response: ServerResponse,
  url: URL
): Promise<boolean> => {
  if (url.pathname !== "/v1/simulators" && !url.pathname.startsWith("/v1/simulators/")) return false
  // Machine authentication has already run. Websites cannot use loopback trust.
  if (request.headers.origin !== undefined || request.headers["sec-fetch-site"] !== undefined)
    throw new HttpFailure(403, "Native clients only")
  response.setHeader("Cache-Control", "no-store")
  const simulators = config.simulators
  if (simulators === undefined || !(await simulatorsAvailable(config)))
    throw new HttpFailure(501, "Simulators need Xcode and the Codevisor app on this Mac")
  try {
    return await handle(simulators, request, response, url)
  } catch (cause) {
    if (cause instanceof SimulatorRequestError) throw new HttpFailure(cause.status, cause.message)
    if (cause instanceof SimulatorCommandError) throw new HttpFailure(502, cause.message)
    throw cause
  }
}

const handle = async (
  simulators: Simulators,
  request: IncomingMessage,
  response: ServerResponse,
  url: URL
): Promise<boolean> => {
  // A server request always has a method.
  const route = [request.method, url.pathname].join(" ")
  const query = (name: string): string => {
    const value = url.searchParams.get(name)
    if (value === null || value.length === 0) throw new HttpFailure(400, `Missing ${name}`)
    return value
  }
  switch (route) {
    case "GET /v1/simulators":
      writeJson(response, 200, await simulators.list())
      return true
    case "GET /v1/simulators/device-type":
      writeJson(response, 200, await simulators.deviceType(query("identifier")))
      return true
    case "GET /v1/simulators/chrome":
      writeJson(response, 200, await simulators.chrome(query("identifier")))
      return true
    case "POST /v1/simulators/devices": {
      const body = await readSchema(request, SimulatorCreateDevice)
      const udid = await simulators.create(
        body.name,
        body.deviceTypeIdentifier,
        body.runtimeIdentifier
      )
      writeJson(response, 201, { udid })
      return true
    }
    case "POST /v1/simulators/devices/action": {
      const body = await readSchema(request, SimulatorDeviceAction)
      await simulators.perform(body.udid, body.action)
      writeJson(response, 200, {})
      return true
    }
    case "POST /v1/simulators/devices/rename": {
      const body = await readSchema(request, SimulatorRenameDevice)
      await simulators.rename(body.udid, body.name)
      writeJson(response, 200, {})
      return true
    }
    case "GET /v1/simulators/settings":
      writeJson(response, 200, await simulators.settings(query("udid")))
      return true
    case "POST /v1/simulators/settings":
      writeJson(
        response,
        200,
        await simulators.changeSettings(await readSchema(request, SimulatorSettingsChange))
      )
      return true
    case "GET /v1/simulators/screenshot": {
      const image = await simulators.screenshot(query("udid"))
      response.writeHead(200, { "Content-Type": "image/png", "Content-Length": image.length })
      response.end(image)
      return true
    }
  }
  throw new HttpFailure(404, "Simulator route not found")
}
