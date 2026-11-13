import { createSocket } from "node:dgram"
import { networkInterfaces, type NetworkInterfaceInfo } from "node:os"

export type LocalNetworkPermission = "allowed" | "denied" | "unavailable"

export type NetworkInterfaces = NodeJS.Dict<ReadonlyArray<NetworkInterfaceInfo>>

export const localNetworkPermission = async (): Promise<LocalNetworkPermission> => {
  if (process.platform !== "darwin") return "allowed"

  const target = localNetworkProbeTarget(networkInterfaces())
  if (target === undefined) return "unavailable"

  const failure = await sendProbe(target)
  return permissionAfter(failure)
}

export const localNetworkProbeTarget = (interfaces: NetworkInterfaces): string | undefined =>
  Object.entries(interfaces)
    .toSorted(([left], [right]) => ethernetFirst(left) - ethernetFirst(right))
    .flatMap(([, infos]) => infos ?? [])
    .map(neighborAddress)
    .find((address) => address !== undefined)

const discardPort = 9
const deniedCode = "EHOSTUNREACH"
const unknownFailure = "unknown"
const unanswered = new Set([undefined, "EHOSTDOWN"])
const minimumPrefixLength = 8
const maximumPrefixLength = 29
const addressBits = 32

const permissionAfter = (failure: string | undefined): LocalNetworkPermission => {
  if (failure === deniedCode) return "denied"
  if (unanswered.has(failure)) return "allowed"
  return "unavailable"
}

const sendProbe = (address: string): Promise<string | undefined> =>
  new Promise((resolve) => {
    const socket = createSocket("udp4")
    let finished = false
    const finish = (error: Error | null) => {
      if (finished) return
      finished = true
      socket.close()
      resolve(errorCode(error))
    }
    socket.on("error", finish)
    socket.send(Buffer.alloc(1), discardPort, address, finish)
  })

const errorCode = (error: Error | null): string | undefined => {
  if (error === null) return undefined
  return "code" in error && typeof error.code === "string" ? error.code : unknownFailure
}

const ethernetFirst = (name: string): number => (name.startsWith("en") ? 0 : 1)

const neighborAddress = (info: NetworkInterfaceInfo): string | undefined => {
  if (!isLanAddress(info)) return undefined

  const prefixLength = Number(info.cidr?.split("/")[1])
  if (!hasRoomForNeighbor(prefixLength)) return undefined

  const own = addressValue(info.address)
  const hostMask = 2 ** (addressBits - prefixLength) - 1
  const network = own - (own % (hostMask + 1))
  const neighbor = [own + 1, own - 1].find((candidate) =>
    isUsableNeighbor(candidate, network, network + hostMask)
  )
  return neighbor === undefined ? undefined : dottedAddress(neighbor)
}

const isLanAddress = (info: NetworkInterfaceInfo): boolean =>
  info.family === "IPv4" && !info.internal && !info.address.startsWith("169.254.")

const hasRoomForNeighbor = (prefixLength: number): boolean =>
  prefixLength >= minimumPrefixLength && prefixLength <= maximumPrefixLength

const isUsableNeighbor = (candidate: number, network: number, broadcast: number): boolean =>
  candidate >= network + 2 && candidate <= broadcast - 2

const addressValue = (address: string): number =>
  address.split(".").reduce((value, octet) => value * 256 + Number(octet), 0)

const dottedAddress = (value: number): string =>
  [24, 16, 8, 0].map((shift) => Math.floor(value / 2 ** shift) % 256).join(".")
