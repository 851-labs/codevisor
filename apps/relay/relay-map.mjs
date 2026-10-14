import { readRelays } from "./gen-fly.mjs"

const { relays } = await readRelays()
const relayMap = relays
  .filter((relay) => relay.advertise)
  .map((relay) => ({ url: `https://${relay.hostname}` }))
console.log(JSON.stringify(relayMap))
