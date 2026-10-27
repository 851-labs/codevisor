import { describe, expect, it } from "vitest"

import { newWebhookSecret, signWebhook, verifyWebhook } from "./standard-webhooks.js"

const specVector = {
  secret: "whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw",
  id: "msg_p5jXN8AQM9LWM0D4loKWxJek",
  timestamp: 1614265330,
  body: '{"test": 2432232314}',
  signature: "v1,g0hM9SsE+OTPJTGt/tmIKtSyZlE3uFJELVlNIOLJ1OE="
}

describe("Standard Webhooks", () => {
  it("signs and verifies the specification's example delivery", () => {
    const headers = {
      "webhook-id": specVector.id,
      "webhook-timestamp": String(specVector.timestamp),
      "webhook-signature": specVector.signature
    }

    const signature = signWebhook(
      specVector.secret,
      specVector.id,
      specVector.timestamp,
      specVector.body
    )
    const verified = verifyWebhook(
      specVector.secret,
      { headers, body: specVector.body },
      specVector.timestamp + 300
    )
    const late = verifyWebhook(
      specVector.secret,
      { headers, body: specVector.body },
      specVector.timestamp + 301
    )

    expect([signature, verified, late]).toEqual([specVector.signature, true, false])
  })

  it("makes whsec_ secrets with 32 random bytes", () => {
    const secret = newWebhookSecret()

    expect(secret).toMatch(/^whsec_/)
    expect(Buffer.from(secret.slice("whsec_".length), "base64")).toHaveLength(32)
    expect(newWebhookSecret()).not.toBe(secret)
  })
})
