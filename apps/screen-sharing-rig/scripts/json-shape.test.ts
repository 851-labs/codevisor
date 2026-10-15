import assert from "node:assert/strict"
import test from "node:test"

import {
  expectShape,
  isBoolean,
  isNumber,
  isRecord,
  isString,
  nullable,
  optional,
  recordOf,
  shape
} from "./json-shape.ts"
import { isRigStatus, isSampleResult } from "./screen-sharing-rig-client.ts"

const isPoint = shape<{ x: number; label?: string; tag: string | null }>({
  x: isNumber,
  label: optional(isString),
  tag: nullable(isString)
})

test("json shapes accept matching objects and reject anything else", () => {
  assert.equal(isRecord({}), true)
  assert.equal(isRecord([]), false)
  assert.equal(isRecord(null), false)
  assert.equal(isBoolean(false), true)
  assert.equal(isBoolean("false"), false)
  assert.equal(isPoint({ x: 1, tag: null }), true)
  assert.equal(isPoint({ x: 1, label: "a", tag: "t" }), true)
  assert.equal(isPoint({ x: 1, label: 2, tag: null }), false)
  assert.equal(isPoint({ x: "1", tag: null }), false)
  assert.equal(isPoint({ x: 1 }), false)
  assert.equal(isPoint("point"), false)
  assert.equal(recordOf(isNumber)({ a: 1, b: 2 }), true)
  assert.equal(recordOf(isNumber)({ a: 1, b: "2" }), false)
  assert.equal(recordOf(isNumber)([1]), false)
})

test("expectShape returns the narrowed value or names what was malformed", () => {
  const point = expectShape({ x: 3, tag: null }, isPoint, "point")
  assert.equal(point.x, 3)
  assert.throws(
    () => expectShape({ x: 3 }, isPoint, "rig.json"),
    /rig.json has an unexpected shape/
  )
})

test("rig responses are checked before they are summarized", () => {
  assert.equal(
    isRigStatus({
      role: "viewer",
      name: "mac",
      build: { commit: "abc", dirty: false, configuration: "release" },
      connection: "connected",
      sessionID: null,
      reconnects: 0,
      uptimeSeconds: 12
    }),
    true
  )
  assert.equal(isRigStatus({ role: "viewer", name: "mac", build: { commit: "abc" } }), false)
  assert.equal(isSampleResult({ samples: 3, report: "/tmp/r.json" }), true)
  assert.equal(isSampleResult({ samples: "3", report: "/tmp/r.json" }), false)
})
