import { useNavigate } from "@tanstack/react-router"
import { TriangleAlertIcon } from "lucide-react"
import { useMemo, useState } from "react"

import { useCreateSession, useHarnesses, usePromptSession, useProjects } from "../../lib/queries"
import { ChipMenu } from "../composer/ChipMenu"
import { Composer } from "../composer/Composer"
import { ProjectMenu } from "./ProjectMenu"

// The session title from the first prompt: its first line, capped at 48
// characters (NewChatView.swift title(from:)).
export function sessionTitleFrom(prompt: string): string {
  const trimmed = prompt.trim()
  const firstLine = trimmed.split("\n", 1)[0] ?? ""
  if (firstLine === "") return "New session"
  return firstLine.length > 48 ? `${firstLine.slice(0, 48)}…` : firstLine
}

// The new-chat page: a centered "What should we build in <project>?" title
// with an inline project dropdown, and the composer. The session is created
// only when the user sends (NewChatView.swift).
export function NewChatScreen({ preferredProjectId }: { preferredProjectId?: string }) {
  const navigate = useNavigate()
  const projectsQuery = useProjects()
  const harnessesQuery = useHarnesses()
  const createSession = useCreateSession()
  const promptSession = usePromptSession()

  const [selectedProjectId, setSelectedProjectId] = useState(preferredProjectId)
  const [selectedHarnessId, setSelectedHarnessId] = useState<string>()
  const [text, setText] = useState("")
  const [error, setError] = useState<string>()

  const projects = useMemo(
    () => (projectsQuery.data ?? []).filter((project) => !project.isArchived),
    [projectsQuery.data]
  )
  const selectedProject =
    projects.find((project) => project.id === selectedProjectId) ?? projects[0]

  const harnesses = useMemo(
    () => (harnessesQuery.data ?? []).filter((harness) => harness.enabled),
    [harnessesQuery.data]
  )
  const selectedHarness =
    harnesses.find((harness) => harness.id === selectedHarnessId) ??
    harnesses.find((harness) => harness.readiness.state === "ready") ??
    harnesses[0]

  const send = async () => {
    if (selectedProject == null || selectedHarness == null || text.trim() === "") return
    setError(undefined)
    try {
      const session = await createSession.mutateAsync({
        projectId: selectedProject.id,
        harnessId: selectedHarness.id,
        title: sessionTitleFrom(text)
      })
      await promptSession.mutateAsync({ id: session.id, text })
      void navigate({ to: "/session/$sessionId", params: { sessionId: session.id } })
    } catch (sendError) {
      setError(sendError instanceof Error ? sendError.message : String(sendError))
    }
  }

  return (
    <div className="flex h-full items-center justify-center p-4 pb-24">
      <div className="flex w-full max-w-[720px] flex-col items-center gap-[22px]">
        {projects.length === 0 ? (
          <div className="flex flex-col items-center gap-2.5 text-center">
            <h1 className="text-[26px] font-semibold">Add a project to start</h1>
            <p className="text-muted-foreground">Use the + next to projects in the sidebar.</p>
          </div>
        ) : (
          <h1 className="text-center text-[26px] leading-relaxed font-semibold text-balance">
            What should we build in{" "}
            <ProjectMenu
              projects={projects}
              selected={selectedProject}
              onSelect={(project) => setSelectedProjectId(project.id)}
            />
            ?
          </h1>
        )}
        {projects.length > 0 && (
          <div className="w-full">
            <Composer
              value={text}
              onValueChange={setText}
              autoFocus
              isSending={createSession.isPending || promptSession.isPending}
              onSend={() => void send()}
              chips={
                harnesses.length === 0 ? (
                  <span className="text-muted-foreground text-sm">No agent installed</span>
                ) : (
                  <ChipMenu
                    label={selectedHarness?.name ?? "Choose agent"}
                    title="Agent"
                    options={harnesses.map((harness) => ({
                      value: harness.id,
                      label: harness.name
                    }))}
                    selectedValue={selectedHarness?.id}
                    onSelect={setSelectedHarnessId}
                  />
                )
              }
            />
          </div>
        )}
        {error != null && (
          <p className="flex items-center gap-1.5 text-sm text-[var(--herdman-status-warn)]">
            <TriangleAlertIcon className="size-4" />
            {error}
          </p>
        )}
      </div>
    </div>
  )
}
