import type { Schema } from "effect"

import { E2bOptions } from "./e2b.js"
import { ModalOptions } from "./modal.js"
import type { EphemeralProviderId } from "./provider.js"
import { TartOptions } from "./tart.js"

export interface EphemeralProviderEntry {
  readonly id: EphemeralProviderId
  readonly displayName: string
  readonly options: Schema.Codec<Readonly<Record<string, unknown>>, unknown>
}

export const EPHEMERAL_PROVIDER_CATALOG: Readonly<
  Record<EphemeralProviderId, EphemeralProviderEntry>
> = {
  e2b: { id: "e2b", displayName: "E2B", options: E2bOptions },
  modal: { id: "modal", displayName: "Modal", options: ModalOptions },
  tart: { id: "tart", displayName: "Tart", options: TartOptions }
}
