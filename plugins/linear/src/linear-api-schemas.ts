import { z } from "zod"

export const linearPerson = z.object({ id: z.string(), name: z.string(), email: z.string() })

export const linearState = z.object({ id: z.string(), name: z.string(), type: z.string() })

export const linearIssue = z.object({
  id: z.string(),
  identifier: z.string(),
  title: z.string(),
  url: z.string(),
  description: z.string().nullish(),
  priority: z.number(),
  priorityLabel: z.string(),
  createdAt: z.string(),
  updatedAt: z.string(),
  state: linearState,
  team: z.object({ id: z.string(), key: z.string(), name: z.string() }),
  project: z.object({ id: z.string(), name: z.string() }).nullish(),
  assignee: linearPerson.nullish(),
  creator: linearPerson.nullish(),
  labels: z.object({ nodes: z.array(z.object({ name: z.string() })) })
})

export const linearComment = z.object({
  id: z.string(),
  body: z.string(),
  url: z.string(),
  createdAt: z.string(),
  user: linearPerson.nullish(),
  issue: linearIssue.nullish()
})

export const linearViewer = z.object({
  id: z.string(),
  name: z.string(),
  email: z.string(),
  url: z.string(),
  organization: z.object({ id: z.string(), name: z.string(), urlKey: z.string() })
})

export const viewerData = z.object({ viewer: linearViewer })
export const issueData = z.object({ issue: linearIssue.nullish() })
export const commentData = z.object({ comment: linearComment.nullish() })
export const stateData = z.object({ workflowState: linearState.nullish() })
export const userData = z.object({ user: linearPerson.nullish() })

export const graphqlResponse = z.object({
  data: z.unknown().optional(),
  errors: z
    .array(
      z.object({
        message: z.string(),
        extensions: z.object({ type: z.string().optional() }).loose().optional()
      })
    )
    .optional()
})

export type LinearPerson = z.infer<typeof linearPerson>
export type LinearState = z.infer<typeof linearState>
export type LinearIssue = z.infer<typeof linearIssue>
export type LinearComment = z.infer<typeof linearComment>
export type LinearViewer = z.infer<typeof linearViewer>
