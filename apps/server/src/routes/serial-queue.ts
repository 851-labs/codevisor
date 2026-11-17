import { swallowError } from "../server-context.js"

export type SerialQueue = <A>(step: () => Promise<A>) => Promise<A>

export const makeSerialQueue = (): SerialQueue => {
  let tail: Promise<unknown> = Promise.resolve()
  return <A>(step: () => Promise<A>): Promise<A> => {
    const next = tail.then(step)
    tail = next.catch(swallowError)
    return next
  }
}
