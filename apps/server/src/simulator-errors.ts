export class SimulatorCommandError extends Error {}

/// A request the caller got wrong (unknown device, bad name); the route answers 4xx.
export class SimulatorRequestError extends Error {
  constructor(
    readonly status: number,
    message: string
  ) {
    super(message)
  }
}
