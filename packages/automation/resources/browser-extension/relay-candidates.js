const FIRST_RELAY_PORT = 49361
const RELAY_PORT_RANGE_SIZE = 39

const inRelayRange = (port) =>
  port >= FIRST_RELAY_PORT && port < FIRST_RELAY_PORT + RELAY_PORT_RANGE_SIZE

const relayCandidates = (relay) => {
  const configured = Number(new URL(relay).port)
  if (!inRelayRange(configured)) return [relay]
  const others = Array.from(
    { length: RELAY_PORT_RANGE_SIZE },
    (_, offset) => FIRST_RELAY_PORT + offset
  ).filter((port) => port !== configured)
  return [configured, ...others].map((port) => {
    const candidate = new URL(relay)
    candidate.port = String(port)
    return candidate.toString()
  })
}

globalThis.codevisorRelays = (relay) => {
  const candidates = relayCandidates(relay)
  let index = 0
  return {
    current: () => candidates[index],
    advance: () => {
      index = (index + 1) % candidates.length
      return index !== 0
    }
  }
}
