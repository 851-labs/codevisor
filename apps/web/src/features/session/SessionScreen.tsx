import { TriangleAlertIcon } from "lucide-react"
import { useEffect, useMemo, useState } from "react"

import { Spinner } from "../../components/ui/spinner"
import { useElementHeight } from "../../lib/useElementHeight"
import {
  useCancelSession,
  useCapabilities,
  usePromptSession,
  useSessionDetail,
  useSetSessionConfig,
  useSetSessionMode,
  useProjects
} from "../../lib/queries"
import { ChipMenu } from "../composer/ChipMenu"
import { Composer } from "../composer/Composer"
import { useIsSessionRunning } from "../sidebar/SessionRow"
import { TerminalPanel } from "../terminal/TerminalPanel"
import { PromptQueue } from "./PromptQueue"
import { StatusBar } from "./StatusBar"
import { Transcript } from "./Transcript"
import { projectFolderPath } from "../../lib/client"

const MIN_TERMINAL_HEIGHT = 120
const MAX_TERMINAL_HEIGHT = 600

// The active session screen: streaming transcript with the composer floating
// over the bottom, the status bar underneath, and the optional terminal panel
// (SessionView.swift SessionScreen).
export function SessionScreen({ sessionId }: { sessionId: string }) {
  const detailQuery = useSessionDetail(sessionId)
  const projectsQuery = useProjects()
  const promptSession = usePromptSession()
  const cancelSession = useCancelSession()
  const setMode = useSetSessionMode()
  const setConfig = useSetSessionConfig()
  const isRunning = useIsSessionRunning(sessionId)

  const [composerText, setComposerText] = useState("")
  const [terminalVisible, setTerminalVisible] = useState(false)
  const [terminalHeight, setTerminalHeight] = useState(240)
  const [composerRef, composerHeight] = useElementHeight()

  const detail = detailQuery.data
  const project = projectsQuery.data?.find(
    (candidate) => candidate.id === detail?.session.projectId
  )

  // Mode + config pickers come from the harness capability (matching the
  // Swift ConfigPrefetcher), with the live mode following stream updates.
  const capabilitiesQuery = useCapabilities(
    project == null ? undefined : projectFolderPath(project)
  )
  const capability = capabilitiesQuery.data?.harnesses.find(
    (candidate) => candidate.harness.id === detail?.session.harnessId
  )
  const currentModeId = detail?.currentModeId ?? capability?.modes?.currentModeId

  const streamFingerprint = useMemo(() => {
    const conversation = detail?.conversation ?? []
    const last = conversation[conversation.length - 1]
    const lastMeta = last != null ? detail?.turnMeta?.[last.id] : undefined
    return [
      conversation.length,
      last?.text.length ?? 0,
      last?.isGenerating ?? false,
      lastMeta?.thoughts.length ?? 0,
      lastMeta?.toolCalls.length ?? 0
    ].join(":")
  }, [detail])

  // ⌘J toggles the terminal panel.
  useEffect(() => {
    const handler = (keyEvent: KeyboardEvent) => {
      if (keyEvent.key === "j" && (keyEvent.metaKey || keyEvent.ctrlKey)) {
        keyEvent.preventDefault()
        setTerminalVisible((visible) => !visible)
      }
    }
    window.addEventListener("keydown", handler)
    return () => window.removeEventListener("keydown", handler)
  }, [])

  const send = () => {
    const text = composerText
    if (text.trim() === "") return
    setComposerText("")
    promptSession.mutate({ id: sessionId, text }, { onError: () => setComposerText(text) })
  }

  if (detail == null) {
    return (
      <div className="flex h-full items-center justify-center">
        {detailQuery.isError ? (
          <p className="flex items-center gap-2 text-sm text-[var(--herdman-status-error)]">
            <TriangleAlertIcon className="size-4" />
            {detailQuery.error instanceof Error ? detailQuery.error.message : "Failed to load"}
          </p>
        ) : (
          <Spinner />
        )}
      </div>
    )
  }

  const composerOverlay = (
    <div ref={composerRef} className="relative mx-auto max-w-[880px] px-6 pt-6 pb-4">
      <div className="flex flex-col gap-2">
        {detail.promptQueue.length > 0 && (
          <PromptQueue sessionId={sessionId} queue={detail.promptQueue} />
        )}
        <Composer
          value={composerText}
          onValueChange={setComposerText}
          placeholder="Ask for follow-up changes"
          commands={detail.availableCommands ?? []}
          isSending={isRunning}
          onSend={send}
          onStop={() => cancelSession.mutate(sessionId)}
          chips={
            <>
              {capability?.configOptions.map((option) => {
                const flatOptions = option.options.flatMap((entry) =>
                  "group" in entry ? entry.options : [entry]
                )
                const current = flatOptions.find(
                  (candidate) => candidate.value === option.currentValue
                )
                return (
                  <ChipMenu
                    key={option.id}
                    title={option.name}
                    label={current?.name ?? option.currentValue}
                    options={flatOptions.map((entry) => ({
                      value: entry.value,
                      label: entry.name
                    }))}
                    selectedValue={option.currentValue}
                    onSelect={(value) =>
                      setConfig.mutate({ id: sessionId, configId: option.id, value })
                    }
                  />
                )
              })}
              {capability?.modes != null &&
                capability.modes.availableModes.length > 1 &&
                !capability.configOptions.some((option) => option.id === "mode") && (
                  <ChipMenu
                    title="Mode"
                    label={
                      capability.modes.availableModes.find((mode) => mode.id === currentModeId)
                        ?.name ?? "Mode"
                    }
                    options={capability.modes.availableModes.map((mode) => ({
                      value: mode.id,
                      label: mode.name
                    }))}
                    selectedValue={currentModeId}
                    onSelect={(modeId) => setMode.mutate({ id: sessionId, modeId })}
                  />
                )}
            </>
          }
        />
      </div>
    </div>
  )

  return (
    <div className="bg-background flex h-full flex-col">
      <Transcript
        conversation={detail.conversation}
        turnMeta={detail.turnMeta}
        errorMessage={detail.streamError}
        composerOverlay={composerOverlay}
        composerHeight={composerHeight}
        streamFingerprint={streamFingerprint}
      />
      <StatusBar
        usage={
          detail.liveUsage ?? {
            used: detail.session.usage?.used,
            size: detail.session.usage?.size,
            costAmount: detail.session.usage?.costAmount,
            costCurrency: detail.session.usage?.costCurrency
          }
        }
        terminalVisible={terminalVisible}
        onToggleTerminal={() => setTerminalVisible((visible) => !visible)}
        onResizeTerminal={(deltaY) =>
          setTerminalHeight((height) =>
            Math.min(MAX_TERMINAL_HEIGHT, Math.max(MIN_TERMINAL_HEIGHT, height + deltaY))
          )
        }
      />
      {terminalVisible && project != null && (
        <div style={{ height: terminalHeight }} className="shrink-0">
          <TerminalPanel
            sessionId={sessionId}
            cwd={detail?.session.cwd ?? projectFolderPath(project) ?? ""}
          />
        </div>
      )}
    </div>
  )
}
