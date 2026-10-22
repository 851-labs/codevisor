import type { HarnessAuthManager } from "@codevisor/harness-manager"

import { HttpFailure } from "../server-context.js"
import type { CodevisorServerServices } from "../server-context.js"

export type AuthRouteResult = true | Promise<boolean> | undefined

export type OptionalAuthMethod = {
  [K in keyof HarnessAuthManager]-?: undefined extends HarnessAuthManager[K] ? K : never
}[keyof HarnessAuthManager]

export type AuthServices<K extends OptionalAuthMethod = never> = CodevisorServerServices & {
  readonly auth: HarnessAuthManager & Required<Pick<HarnessAuthManager, K>>
}

export const requireAuth = (services: CodevisorServerServices): AuthServices => {
  if (!hasAuth(services)) throw authUnavailable()
  return services
}

export const requireAuthMethods = <K extends OptionalAuthMethod>(
  services: CodevisorServerServices,
  method: K,
  ...alsoRequired: ReadonlyArray<K>
): AuthServices<K> => {
  if (!hasAuthMethod(services, method)) throw authUnavailable()
  if (!alsoRequired.every((next) => definesAuthMethod(services, next))) throw authUnavailable()
  return services
}

const hasAuth = (services: CodevisorServerServices): services is AuthServices =>
  services.auth !== undefined

const hasAuthMethod = <K extends OptionalAuthMethod>(
  services: CodevisorServerServices,
  method: K
): services is AuthServices<K> => services.auth?.[method] !== undefined

const definesAuthMethod = (services: AuthServices, method: OptionalAuthMethod): boolean =>
  services.auth[method] !== undefined

const authUnavailable = (): HttpFailure =>
  new HttpFailure(501, "Harness authentication unavailable")
