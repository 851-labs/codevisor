import { useNavigate } from "@tanstack/react-router"
import { FolderIcon, FolderPlusIcon, CheckCircle2Icon, TriangleAlertIcon } from "lucide-react"
import { useState } from "react"

import { Button } from "../../components/ui/button"
import { Spinner } from "../../components/ui/spinner"
import { Switch } from "../../components/ui/switch"
import { cn } from "../../lib/cn"
import { pickProjectFolder, projectNameFromPath } from "../../lib/folder-picker"
import { useEnsureProject, useHarnesses, useSetHarnessEnabled } from "../../lib/queries"

const STEPS = ["welcome", "harnesses", "project"] as const
type Step = (typeof STEPS)[number]

function markOnboarded(): void {
  try {
    window.localStorage.setItem("herdman-onboarded", "true")
  } catch {
    // Non-fatal; the guard will show onboarding again next launch.
  }
}

function PageDots({ step }: { step: Step }) {
  return (
    <div className="flex items-center gap-1.5">
      {STEPS.map((candidate) => (
        <span
          key={candidate}
          className={cn(
            "size-1.5 rounded-full",
            candidate === step ? "bg-foreground" : "bg-muted-foreground/30"
          )}
        />
      ))}
    </div>
  )
}

function WelcomeStep() {
  return (
    <div className="flex flex-col gap-3.5">
      <h1 className="text-[38px] leading-tight font-bold">Welcome to HerdMan</h1>
      <p className="text-muted-foreground text-lg">
        HerdMan runs your local ACP coding agents in one place. Let&apos;s get you set up in a few
        quick steps.
      </p>
    </div>
  )
}

function HarnessesStep() {
  const harnessesQuery = useHarnesses()
  const setHarnessEnabled = useSetHarnessEnabled()
  const harnesses = harnessesQuery.data ?? []

  return (
    <div className="flex flex-col gap-4">
      <div className="flex flex-col gap-1.5">
        <h1 className="text-[28px] font-bold">Choose your harnesses</h1>
        <p className="text-muted-foreground">
          These are the ACP harnesses we found on your computer. Turn on the ones you&apos;d like to
          use.
        </p>
      </div>
      {harnessesQuery.isPending ? (
        <div className="text-muted-foreground flex items-center gap-2 py-2 text-sm">
          <Spinner />
          Looking for installed harnesses…
        </div>
      ) : harnesses.length === 0 ? (
        <div className="flex items-start gap-2.5 py-1">
          <TriangleAlertIcon className="mt-0.5 size-4 shrink-0 text-[var(--herdman-status-warn)]" />
          <div className="flex flex-col gap-0.5">
            <p className="text-sm font-medium">No harnesses found</p>
            <p className="text-muted-foreground text-sm">
              Install Claude Code, Codex, or another ACP agent, then come back to detect it.
            </p>
          </div>
        </div>
      ) : (
        <div className="rounded-xl bg-[var(--herdman-card-bg)] px-3.5 py-1">
          {harnesses.map((harness, index) => (
            <div key={harness.id}>
              {index > 0 && <div className="bg-border h-px" />}
              <label className="flex cursor-default items-center justify-between py-2.5 text-sm">
                <span className="flex flex-col">
                  <span>{harness.name}</span>
                  {harness.readiness.state === "unavailable" && (
                    <span className="text-muted-foreground text-xs">
                      {harness.readiness.detail ?? "Unavailable"}
                    </span>
                  )}
                </span>
                <Switch
                  checked={harness.enabled}
                  onCheckedChange={(checked) =>
                    setHarnessEnabled.mutate({ id: harness.id, enabled: checked })
                  }
                />
              </label>
            </div>
          ))}
        </div>
      )}
    </div>
  )
}

function ProjectStep({
  folderPath,
  onPick
}: {
  folderPath: string | undefined
  onPick: (path: string) => void
}) {
  return (
    <div className="flex flex-col gap-4">
      <div className="flex flex-col gap-1.5">
        <h1 className="text-[28px] font-bold">Open a project</h1>
        <p className="text-muted-foreground">
          Pick a folder to work in. HerdMan opens a new chat scoped to this project.
        </p>
      </div>
      <button
        type="button"
        onClick={() => {
          void pickProjectFolder().then((path) => {
            if (path != null) onPick(path)
          })
        }}
        className={cn(
          "flex cursor-default items-center gap-3 rounded-xl p-3.5 text-left outline-none",
          "bg-[var(--herdman-card-bg)] hover:bg-[var(--herdman-card-hover-bg)]",
          folderPath != null && "border-ring border"
        )}
      >
        {folderPath != null ? (
          <FolderIcon className="text-foreground size-5 shrink-0" />
        ) : (
          <FolderPlusIcon className="text-foreground size-5 shrink-0" />
        )}
        <span className="flex min-w-0 flex-1 flex-col">
          <span className="text-sm font-medium">
            {folderPath != null ? projectNameFromPath(folderPath) : "Choose a folder…"}
          </span>
          {folderPath != null && (
            <span className="text-muted-foreground truncate text-xs">{folderPath}</span>
          )}
        </span>
        {folderPath != null && <CheckCircle2Icon className="text-foreground size-4 shrink-0" />}
      </button>
    </div>
  )
}

// First-launch onboarding: a short paginated flow — welcome, choose your
// harnesses, open a project folder. Completing the last step creates the
// project and opens a new chat scoped to it (OnboardingView.swift).
export function OnboardingFlow() {
  const navigate = useNavigate()
  const ensureProject = useEnsureProject()
  const [step, setStep] = useState<Step>("welcome")
  const [folderPath, setFolderPath] = useState<string>()
  const [isFinishing, setIsFinishing] = useState(false)
  const [finishError, setFinishError] = useState<string>()

  const stepIndex = STEPS.indexOf(step)

  const finish = async () => {
    setIsFinishing(true)
    setFinishError(undefined)
    try {
      let projectId: string | undefined
      if (folderPath != null) {
        // Reuses an existing project for the folder — the database is
        // shared with the macOS app, so the folder may already be added.
        const project = await ensureProject.mutateAsync(folderPath)
        projectId = project.id
      }
      markOnboarded()
      void navigate({ to: "/", search: projectId != null ? { project: projectId } : {} })
    } catch (error) {
      setFinishError(error instanceof Error ? error.message : String(error))
    } finally {
      setIsFinishing(false)
    }
  }

  const advance = () => {
    if (step === "project") {
      void finish()
      return
    }
    setStep(STEPS[stepIndex + 1] ?? "project")
  }

  return (
    <div className="bg-background flex h-full flex-col">
      <div className="flex min-h-0 flex-1 items-center justify-center overflow-y-auto px-10 py-8">
        <div className="w-full max-w-[440px]">
          {step === "welcome" && <WelcomeStep />}
          {step === "harnesses" && <HarnessesStep />}
          {step === "project" && <ProjectStep folderPath={folderPath} onPick={setFolderPath} />}
          {finishError != null && (
            <p className="mt-4 flex items-start gap-2 text-sm text-[var(--herdman-status-error)]">
              <TriangleAlertIcon className="mt-0.5 size-4 shrink-0" />
              {finishError}
            </p>
          )}
        </div>
      </div>
      <div className="mx-auto flex w-full max-w-[440px] items-center px-10 py-6">
        <div className="w-16">
          {step !== "welcome" && (
            <Button
              variant="ghost"
              size="sm"
              onClick={() => setStep(STEPS[stepIndex - 1] ?? "welcome")}
            >
              Back
            </Button>
          )}
        </div>
        <div className="flex flex-1 justify-center">
          <PageDots step={step} />
        </div>
        <div className="flex w-32 justify-end gap-2">
          {step === "project" && folderPath == null && (
            <Button variant="ghost" size="sm" disabled={isFinishing} onClick={() => void finish()}>
              Skip
            </Button>
          )}
          <Button
            onClick={advance}
            disabled={isFinishing || (step === "project" && folderPath == null)}
          >
            {step === "project" ? (isFinishing ? "Opening…" : "Open project") : "Continue"}
          </Button>
        </div>
      </div>
    </div>
  )
}
