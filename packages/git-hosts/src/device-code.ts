import type { DeviceCode } from "./git-host.js"

export const parseDeviceCode = (text: string): string | undefined =>
  (/code:?\s+([A-Z0-9]{4,}(?:-[A-Z0-9]{4,})+)/i.exec(text) ??
    /\b([A-Z0-9]{4}-[A-Z0-9]{4})\b/.exec(text))?.[1]

export const parseVerificationUrl = (text: string): string | undefined =>
  /(https?:\/\/[^\s"'<>]+)/.exec(text)?.[1]?.replace(/[.,;:)]+$/, "")

export const parseDevicePrompt = (text: string): DeviceCode | undefined => {
  const userCode = parseDeviceCode(text)
  const verificationUrl = parseVerificationUrl(text)
  if (userCode === undefined || verificationUrl === undefined) return undefined

  return { userCode, verificationUrl }
}
