import { APPLE_CONTAINER_DEFINITION } from "./apple-container.js"
import { DAYTONA_DEFINITION } from "./daytona.js"
import { E2B_DEFINITION } from "./e2b.js"
import { MODAL_DEFINITION } from "./modal.js"
import type { SandboxProviderDefinition, SandboxProviderId } from "./provider.js"
import { TART_ORCHARD_DEFINITION } from "./tart-orchard.js"
import { TART_DEFINITION } from "./tart.js"
import { VERCEL_DEFINITION } from "./vercel.js"

export const SANDBOX_PROVIDER_DEFINITIONS: ReadonlyArray<SandboxProviderDefinition> = [
  TART_DEFINITION,
  TART_ORCHARD_DEFINITION,
  APPLE_CONTAINER_DEFINITION,
  E2B_DEFINITION,
  MODAL_DEFINITION,
  VERCEL_DEFINITION,
  DAYTONA_DEFINITION
]

export const sandboxDefinition = (id: SandboxProviderId): SandboxProviderDefinition | undefined =>
  SANDBOX_PROVIDER_DEFINITIONS.find((definition) => definition.id === id)
