export type Cancel = () => void

export interface Clock {
  now(): number
  every(intervalMs: number, task: () => void): Cancel
}

export const systemClock: Clock = {
  now: () => Date.now(),
  every: (intervalMs, task) => {
    const timer = setInterval(task, intervalMs)
    return () => clearInterval(timer)
  }
}

export const isoTime = (milliseconds: number): string => new Date(milliseconds).toISOString()
