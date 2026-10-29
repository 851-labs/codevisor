export interface RoleFenceToken {
  readonly role: string
  readonly version: number
}

export interface RoleFence {
  readonly admit: (token: RoleFenceToken) => boolean
  readonly highest: (role: string) => number | undefined
}

export const makeRoleFence = (seen: ReadonlyMap<string, number> = new Map()): RoleFence => {
  const highestSeen = new Map(seen)
  return {
    admit: (token) => {
      if (isStale(highestSeen.get(token.role), token)) return false

      highestSeen.set(token.role, token.version)
      return true
    },
    highest: (role) => highestSeen.get(role)
  }
}

const isStale = (highest: number | undefined, token: RoleFenceToken): boolean =>
  highest !== undefined && token.version < highest
