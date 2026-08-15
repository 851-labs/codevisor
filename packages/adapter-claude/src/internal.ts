// Shared internals for the split Claude provider modules.

export interface Deferred<A> {
  readonly promise: Promise<A>
  readonly resolve: (value: A) => void
  readonly reject: (error: unknown) => void
}

export const deferred = <A>(): Deferred<A> => {
  let resolveFn!: (value: A) => void
  let rejectFn!: (error: unknown) => void
  const promise = new Promise<A>((resolvePromise, rejectPromise) => {
    resolveFn = resolvePromise
    rejectFn = rejectPromise
  })
  promise.catch(() => undefined)
  return { promise, reject: rejectFn, resolve: resolveFn }
}

export const isRecord = (value: unknown): value is Record<string, unknown> =>
  typeof value === "object" && value !== null
