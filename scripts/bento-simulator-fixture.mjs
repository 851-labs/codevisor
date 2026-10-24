import process from "node:process"

import { makeSimulators, systemSimulatorEnvironment } from "../apps/server/src/simulators.ts"

const [udid] = process.argv.slice(2)
if (udid === undefined) throw new Error("Usage: bun scripts/bento-simulator-fixture.mjs <udid>")

const simulators = makeSimulators(systemSimulatorEnvironment)
const list = await simulators.list()
const device = list.devices.find((candidate) => candidate.udid.toUpperCase() === udid.toUpperCase())
if (device === undefined) throw new Error(`Simulator ${udid} is not listed`)
const deviceType = await simulators.deviceType(device.deviceType.identifier)
const chromeIdentifiers = [
  ...new Set(
    [
      deviceType.chromeIdentifier,
      ...deviceType.displays.map((display) => display.chromeIdentifier)
    ].filter((identifier) => identifier !== undefined)
  )
]
const chromes = Object.fromEntries(
  await Promise.all(
    chromeIdentifiers.map(async (identifier) => [identifier, await simulators.chrome(identifier)])
  )
)
process.stdout.write(
  JSON.stringify({
    udid: device.udid,
    list: { ...list, devices: [device] },
    deviceTypes: { [device.deviceType.identifier]: deviceType },
    chromes,
    settings: await simulators.settings(device.udid)
  })
)
