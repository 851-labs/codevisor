import type { Schema } from "effect"

import { GitAuthFlow, GitHostAuthStatus, StartGitAuthRequest } from "./git-auth.js"
import type { Endpoint } from "./openapi-endpoints.js"
import {
  CheckProjectCloneAccessRequest,
  CreateProjectFromGitRequest,
  Project,
  ProjectCloneAccess,
  ProjectCloneSettings,
  ProjectSetupSource,
  PublishProjectRemoteRequest,
  ReadProjectEnvFilesRequest,
  ReadProjectEnvFilesResponse,
  UpdateProjectCloneSettingsRequest
} from "./projects.js"

export const projectSetupRequestSchemas: Partial<Record<Endpoint, Schema.Constraint>> = {
  "POST /v1/projects/from-git": CreateProjectFromGitRequest,
  "PUT /v1/projects/clone-settings": UpdateProjectCloneSettingsRequest,
  "POST /v1/projects/clone-access": CheckProjectCloneAccessRequest,
  "POST /v1/git/auth/login": StartGitAuthRequest,
  "POST /v1/projects/:id/env-files/read": ReadProjectEnvFilesRequest,
  "POST /v1/projects/:id/remote": PublishProjectRemoteRequest
}

export const projectSetupResponseSchemas: Partial<Record<Endpoint, Schema.Constraint>> = {
  "POST /v1/projects/from-git": Project,
  "GET /v1/projects/clone-settings": ProjectCloneSettings,
  "PUT /v1/projects/clone-settings": ProjectCloneSettings,
  "GET /v1/projects/:id/setup-source": ProjectSetupSource,
  "POST /v1/projects/clone-access": ProjectCloneAccess,
  "GET /v1/git/auth/status": GitHostAuthStatus,
  "POST /v1/git/auth/login": GitAuthFlow,
  "GET /v1/git/auth/login/:flowId": GitAuthFlow,
  "POST /v1/projects/:id/env-files/read": ReadProjectEnvFilesResponse,
  "POST /v1/projects/:id/remote": Project
}
