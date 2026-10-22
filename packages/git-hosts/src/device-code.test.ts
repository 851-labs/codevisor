import { describe, expect, it } from "vitest"

import { parseDeviceCode, parseVerificationUrl } from "./device-code.js"

describe("device code prompts", () => {
  it("reads device codes and verification links from CLI output", () => {
    expect(parseDeviceCode("! First copy your one-time code: A6A2-6357")).toBe("A6A2-6357")
    expect(parseDeviceCode("Enter ABCD-EFGH at the page")).toBe("ABCD-EFGH")
    expect(parseDeviceCode("no code here")).toBeUndefined()
    expect(parseVerificationUrl("Open https://github.com/login/device.")).toBe(
      "https://github.com/login/device"
    )
    expect(parseVerificationUrl("nothing")).toBeUndefined()
  })
})
