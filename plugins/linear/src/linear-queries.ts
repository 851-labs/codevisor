const issueFields = `
  id identifier title url description priority priorityLabel createdAt updatedAt
  state { id name type }
  team { id key name }
  project { id name }
  assignee { id name email }
  creator { id name email }
  labels { nodes { name } }
`

export const linearQueries = {
  viewer: "query Viewer { viewer { id name email url organization { id name urlKey } } }",
  issue: `query Issue($id: String!) { issue(id: $id) { ${issueFields} } }`,
  comment: `query Comment($id: String!) {
    comment(id: $id) { id body url createdAt user { id name email } issue { ${issueFields} } }
  }`,
  state: "query State($id: String!) { workflowState(id: $id) { id name type } }",
  user: "query User($id: String!) { user(id: $id) { id name email } }"
}
