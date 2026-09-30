// Prints the Worker's RELAY_MAP: the relays in relays.json marked
// `advertise`. deploy-cloud.yml passes it to `wrangler deploy --var`, so
// relays.json is the only list of relays to maintain.
import { readRelays } from "./gen-fly.mjs"

const { relays } = await readRelays()
const relayMap = relays
  .filter((relay) => relay.advertise)
  .map((relay) => ({ url: `https://${relay.hostname}` }))
console.log(JSON.stringify(relayMap))
