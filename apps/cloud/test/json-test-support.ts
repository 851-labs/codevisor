import { CloudMachinePresence, decode } from "@codevisor/api"
import { z } from "zod"

export const readJson = async <Output>(
  response: Response,
  schema: z.ZodType<Output>
): Promise<Output> => schema.parse(await response.json())

export const parseJson = <Output>(raw: unknown, schema: z.ZodType<Output>): Output => {
  if (typeof raw !== "string") throw new Error(`expected a JSON string, got ${typeof raw}`)
  return schema.parse(JSON.parse(raw))
}

export const jsonRecord = z.record(z.string(), z.unknown())

export const TokenBody = z.object({ token: z.string() })

export const KeyBody = z.object({ key: z.string() })

export const UrlBody = z.object({ url: z.string() })

export const AuthProvidersBody = z.object({ authProviders: z.array(z.string()) })

export const SessionUserBody = z.object({ user: z.looseObject({ id: z.string() }) }).nullable()

export const MachinesBody = z.object({
  machines: z.array(z.unknown().transform(decode(CloudMachinePresence)))
})
