import { Schema } from "effect"

import {
  AddBotProjectRequest,
  Bot,
  CreateBotRequest,
  ForkBotRequest,
  UpdateBotRequest
} from "./bots.js"
import type { Endpoint } from "./openapi-endpoints.js"

export const botRequestSchemas: Partial<Record<Endpoint, Schema.Constraint>> = {
  "POST /v1/bots": CreateBotRequest,
  "PATCH /v1/bots/:id": UpdateBotRequest,
  "POST /v1/bots/:id/projects": AddBotProjectRequest,
  "POST /v1/bots/:id/fork": ForkBotRequest
}

export const botResponseSchemas: Partial<Record<Endpoint, Schema.Constraint>> = {
  "GET /v1/bots": Schema.Array(Bot),
  "POST /v1/bots": Bot,
  "GET /v1/bots/:id": Bot,
  "PATCH /v1/bots/:id": Bot,
  "POST /v1/bots/:id/projects": Bot,
  "POST /v1/bots/:id/fork": Bot,
  "DELETE /v1/bots/:id/projects/:projectId": Bot
}
