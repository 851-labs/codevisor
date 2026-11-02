export interface InspectionSteps {
  readonly enter: (step: string) => void
}

export const untrackedSteps: InspectionSteps = { enter: () => {} }

export interface InspectionStepLog extends InspectionSteps {
  readonly describe: () => string | undefined
}

interface StepTiming {
  readonly step: string
  readonly startedAt: number
}

export const makeInspectionStepLog = (
  now: () => number = () => performance.now()
): InspectionStepLog => {
  const timings: StepTiming[] = []
  return {
    enter: (step) => {
      timings.push({ step, startedAt: now() })
    },
    describe: () => {
      const current = timings.at(-1)
      if (current === undefined) return undefined

      const stuck = `stuck in ${current.step} for ${elapsedSince(current.startedAt, now())}ms`
      const finished = finishedSteps(timings)
      if (finished.length === 0) return stuck
      return `${stuck}, after ${finished.join(", ")}`
    }
  }
}

const finishedSteps = (timings: ReadonlyArray<StepTiming>): ReadonlyArray<string> =>
  timings
    .slice(0, -1)
    .map(
      (timing, index) =>
        `${timing.step} ${elapsedSince(timing.startedAt, timings[index + 1]!.startedAt)}ms`
    )

const elapsedSince = (startedAt: number, endedAt: number): number => Math.round(endedAt - startedAt)
