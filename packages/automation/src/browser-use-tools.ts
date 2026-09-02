import type { Tool } from "@modelcontextprotocol/sdk/types.js"
import { browserUseNativeTools } from "./browser-use-tools-native.js"
import { browserUsePlaywrightTools } from "./browser-use-tools-playwright.js"
import { browserUsePageTools } from "./browser-use-tools-page.js"

export const browserUseTools: ReadonlyArray<Tool> = [
  ...browserUseNativeTools,
  ...browserUsePlaywrightTools,
  ...browserUsePageTools
]
