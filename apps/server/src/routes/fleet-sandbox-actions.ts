import { FleetSandboxRequest, type FleetSandboxAnswer } from "@codevisor/api"
import { Option, Schema } from "effect"

import { HttpFailure, type CodevisorServerServices } from "../server-context.js"
import type { FleetCall } from "./fleet-calls.js"

const decodeRequest = Schema.decodeUnknownOption(FleetSandboxRequest)

export const receiveSandboxAction = async (
  services: CodevisorServerServices,
  call: FleetCall,
  args: unknown
): Promise<FleetSandboxAnswer> => {
  if (!call.verified)
    throw new HttpFailure(403, "Only machines on this account can manage sandboxes")
  const sandboxes = services.sandboxes?.sandboxes
  if (sandboxes === undefined) throw new HttpFailure(501, "Sandboxes are unavailable here")
  const request = decodeRequest(args)
  if (Option.isNone(request)) throw new HttpFailure(400, "Expected { request, record }")

  return sandboxes.receive(request.value)
}
