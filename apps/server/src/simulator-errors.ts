export class SimulatorCommandError extends Error {}

export class SimulatorRequestError extends Error {
  constructor(
    readonly status: number,
    message: string
  ) {
    super(message)
  }
}
