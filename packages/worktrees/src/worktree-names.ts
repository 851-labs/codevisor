import { randomUUID } from "node:crypto"

import { dishNames, drinkNames, pantryNames, sweetNames } from "./worktree-names-dishes.js"
import {
  dairyNames,
  grainNutNames,
  herbSpiceNames,
  produceNames,
  proteinNames
} from "./worktree-names-ingredients.js"

// Production worktrees draw from the combined single-word food vocabulary.
export const productionFoodWorktreeNames: ReadonlyArray<string> = [
  ...produceNames,
  ...grainNutNames,
  ...herbSpiceNames,
  ...dairyNames,
  ...proteinNames,
  ...dishNames,
  ...sweetNames,
  ...pantryNames,
  ...drinkNames
]

const randomNameAttempts = 20
const randomIdAttempts = 20

const randomNameIndex = (random: () => number): number =>
  Math.min(
    productionFoodWorktreeNames.length - 1,
    Math.floor(random() * productionFoodWorktreeNames.length)
  )

const randomNameAt = (random: () => number): string =>
  productionFoodWorktreeNames[randomNameIndex(random)]!

const defaultRandomId = (): string => randomUUID().replaceAll("-", "").slice(0, 8)

/// Tries inexpensive random picks first, then scans the complete food pool from
/// a random offset. A random ID is appended only when every base name is in use.
export const availableProductionWorktreeName = (
  existing: ReadonlySet<string>,
  random: () => number = Math.random,
  randomId: () => string = defaultRandomId
): string => {
  for (let attempt = 0; attempt < randomNameAttempts; attempt += 1) {
    const candidate = randomNameAt(random)
    if (!existing.has(candidate)) {
      return candidate
    }
  }

  const startIndex = randomNameIndex(random)
  for (let offset = 0; offset < productionFoodWorktreeNames.length; offset += 1) {
    const index = (startIndex + offset) % productionFoodWorktreeNames.length
    const candidate = productionFoodWorktreeNames[index]!
    if (!existing.has(candidate)) {
      return candidate
    }
  }

  const base = randomNameAt(random)
  for (let attempt = 0; attempt < randomIdAttempts; attempt += 1) {
    const candidate = `${base}-${randomId()}`
    if (!existing.has(candidate)) {
      return candidate
    }
  }
  throw new Error("Unable to allocate a unique production worktree name")
}
