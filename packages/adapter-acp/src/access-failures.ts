import * as acp from "@agentclientprotocol/sdk"
import { harnessFailureStop, type HarnessFailure } from "@codevisor/agent-runtime"

import type { AcpPromptResult } from "./connection.js"
import { dataField, userFacingDetail, type AcpRequestFailure } from "./usage-limit-failures.js"

export const forbiddenPromptStop = (cause: unknown): AcpPromptResult | undefined => {
  if (!(cause instanceof acp.RequestError)) return undefined

  const stop = harnessFailureStop(harnessFailure(cause))
  if (stop.stopKind !== "forbidden") return undefined

  return { stopReason: "end_turn", ...stop }
}

const statusFields = ["httpStatusCode", "statusCode", "status"]

const errorCodeFields = ["errorKind", "codexErrorInfo", "errorName", "code"]

const harnessFailure = (failure: AcpRequestFailure): HarnessFailure => ({
  message: userFacingDetail(failure.message),
  status: httpStatus(failure),
  code: errorCode(failure)
})

const httpStatus = (failure: AcpRequestFailure): number | undefined =>
  [...statusFields.map((key) => dataField(failure, key)), failure.code].find(
    (value): value is number => typeof value === "number"
  )

const errorCode = (failure: AcpRequestFailure): string | undefined =>
  errorCodeFields
    .map((key) => dataField(failure, key))
    .find((value): value is string => typeof value === "string")
