import type { Migration } from "./migration-types.js"
import { migrations01To08 } from "./migrations-01-08.js"
import { migrations09To29 } from "./migrations-09-29.js"
import { migrations30To33 } from "./migrations-30-33.js"
import { migrations34To45 } from "./migrations-34-45.js"
import { migrations46 } from "./migrations-46.js"
import { migrations47 } from "./migrations-47.js"
import { migrations48 } from "./migrations-48.js"
import { migrations49 } from "./migrations-49.js"
import { migrations50 } from "./migrations-50.js"
import { migrations51 } from "./migrations-51.js"
import { migrations52 } from "./migrations-52.js"
import { migrations53 } from "./migrations-53.js"
import { migrations54 } from "./migrations-54.js"
import { migrations55 } from "./migrations-55.js"
import { migrations56 } from "./migrations-56.js"
import { migrations57 } from "./migrations-57.js"
import { migrations58 } from "./migrations-58.js"
import { migrations59 } from "./migrations-59.js"
import { migrations60 } from "./migrations-60.js"
import { migrations61 } from "./migrations-61.js"
import { migrations62 } from "./migrations-62.js"
import { migrations63 } from "./migrations-63.js"
import { migrations64 } from "./migrations-64.js"
import { migrations65 } from "./migrations-65.js"
import { migrations66 } from "./migrations-66.js"
import { migrations67 } from "./migrations-67.js"
import { migrations68 } from "./migrations-68.js"
import { migrations69 } from "./migrations-69.js"
import { migrations70 } from "./migrations-70.js"
import { migrations71 } from "./migrations-71.js"
import { migrations72 } from "./migrations-72.js"
import { migrations73 } from "./migrations-73.js"
import { migrations74 } from "./migrations-74.js"

export type { Migration } from "./migration-types.js"

export const migrations: ReadonlyArray<Migration> = [
  ...migrations01To08,
  ...migrations09To29,
  ...migrations30To33,
  ...migrations34To45,
  ...migrations46,
  ...migrations47,
  ...migrations48,
  ...migrations49,
  ...migrations50,
  ...migrations51,
  ...migrations52,
  ...migrations53,
  ...migrations54,
  ...migrations55,
  ...migrations56,
  ...migrations57,
  ...migrations58,
  ...migrations59,
  ...migrations60,
  ...migrations61,
  ...migrations62,
  ...migrations63,
  ...migrations64,
  ...migrations65,
  ...migrations66,
  ...migrations67,
  ...migrations68,
  ...migrations69,
  ...migrations70,
  ...migrations71,
  ...migrations72,
  ...migrations73,
  ...migrations74
]
