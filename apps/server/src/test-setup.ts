import { afterEach, beforeEach } from "vitest"

import { blockExternalFetch, closeTestResources } from "./test-support-resources.js"

beforeEach(blockExternalFetch)
afterEach(closeTestResources)
