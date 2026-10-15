export type Column<T> = (value: unknown) => value is T

export type RowColumns<R> = { readonly [K in keyof R]-?: Column<R[K]> }

export interface RowReader<R> {
  readonly columns: RowColumns<R>
  readonly is: (value: unknown) => value is R
  readonly one: (value: unknown) => R
  readonly maybe: (value: unknown) => R | undefined
  readonly all: (values: ReadonlyArray<unknown>) => Array<R>
}

export const text = (value: unknown): value is string => typeof value === "string"

export const integer = (value: unknown): value is number => typeof value === "number"

export const real: Column<number> = integer

export const blob = (value: unknown): value is Buffer => Buffer.isBuffer(value)

export const nullable =
  <T>(column: Column<T>): Column<T | null> =>
  (value: unknown): value is T | null =>
    value === null || column(value)

export const optional =
  <T>(column: Column<T>): Column<T | undefined> =>
  (value: unknown): value is T | undefined =>
    value === undefined || column(value)

export const literal =
  <const T extends string>(...values: ReadonlyArray<T>): Column<T> =>
  (value: unknown): value is T =>
    values.some((candidate) => candidate === value)

const isObject = (value: unknown): value is object => typeof value === "object" && value !== null

export const rowReader = <R>(columns: RowColumns<R>): RowReader<R> => {
  const entries = Object.entries<Column<unknown>>(columns)
  const mismatchedColumn = (value: object): string | undefined =>
    entries.find(([key, column]) => !column(Reflect.get(value, key)))?.[0]
  const is = (value: unknown): value is R =>
    isObject(value) && mismatchedColumn(value) === undefined
  const one = (value: unknown): R => {
    if (is(value)) return value
    if (!isObject(value)) throw new Error("Expected a database row")
    throw new Error(`Unexpected database value in column ${mismatchedColumn(value)}`)
  }
  const maybe = (value: unknown): R | undefined => (value === undefined ? undefined : one(value))
  const all = (values: ReadonlyArray<unknown>): Array<R> => values.map(one)
  return { columns, is, one, maybe, all }
}
