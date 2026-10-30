export interface HarnessChoices {
  readonly start: (id: string, harnessId: string | undefined) => void
  readonly choose: (id: string, harnessId: string) => void
  readonly chosen: (id: string) => string | undefined
  readonly forget: (id: string) => void
}

export const makeHarnessChoices = (): HarnessChoices => {
  const choices = new Map<string, string | undefined>()
  return {
    start: (id, harnessId) => {
      choices.set(id, harnessId)
    },
    choose: (id, harnessId) => {
      if (choices.has(id)) choices.set(id, harnessId)
    },
    chosen: (id) => choices.get(id),
    forget: (id) => {
      choices.delete(id)
    }
  }
}
