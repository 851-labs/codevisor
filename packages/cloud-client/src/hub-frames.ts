import {
  decodeRelayEnvelopes,
  type CloudRelayInfo,
  type HubToMachine,
  type WireRelayEnvelope
} from "@codevisor/api"

type HubFrameType = HubToMachine["t"]

export type HubFrame<T extends HubFrameType> = Extract<HubToMachine, { t: T }>

export interface WelcomeResume {
  readonly resumed: boolean
  readonly replayedFrames: number
}

export interface TunnelConfig {
  readonly relays: readonly CloudRelayInfo[]
  readonly enabled: boolean
}

export const decodeRelayBatch = (data: Uint8Array): WireRelayEnvelope[] | undefined => {
  try {
    return decodeRelayEnvelopes(data)
  } catch {
    return undefined
  }
}

export const tunnelConfigOf = (welcome: HubFrame<"welcome">): TunnelConfig => ({
  relays: welcome.relays ?? [],
  enabled: welcome.tunnel === "on"
})
