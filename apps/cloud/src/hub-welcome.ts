import {
  type AppHello,
  CLOUD_PROTOCOL_VERSION,
  type CloudMachinePresence,
  encodeCloudFrame
} from "@codevisor/api"

import type { SocketAttachment } from "./hub-schema.js"

export interface WelcomeHead {
  t: "welcome"
  protocol: number
  connectionId: string
}

export interface WelcomeMachines {
  machines?: CloudMachinePresence[]
}

export interface WelcomeResume {
  resume: string
  resumed?: true
}

export const welcomeHead = (connectionId: string): WelcomeHead => ({
  t: "welcome",
  protocol: CLOUD_PROTOCOL_VERSION,
  connectionId
})

export const resumeFields = (token: string, resumed: boolean): WelcomeResume => ({
  resume: token,
  ...(resumed ? { resumed: true as const } : {})
})

export const answerPing = (socket: WebSocket): void => {
  socket.send(encodeCloudFrame({ t: "pong" }))
}

export const adoptAppIdentity = (
  attachment: SocketAttachment,
  frame: typeof AppHello.Type
): void => {
  attachment.deviceId = frame.device.deviceId
  attachment.publicKey = frame.device.publicKey
}

export const completeHello = (socket: WebSocket, attachment: SocketAttachment): void => {
  attachment.helloDone = true
  socket.serializeAttachment(attachment)
}
