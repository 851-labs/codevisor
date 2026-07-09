import type { SessionConfigOption } from "@herdman/api"
import { createFileRoute } from "@tanstack/react-router"
import { Code2Icon, FolderIcon, GitBranchIcon, ListTodoIcon, TargetIcon } from "lucide-react"
import { useState } from "react"

import { ChipMenu } from "../../features/composer/ChipMenu"
import { Composer } from "../../features/composer/Composer"
import { ModelConfigMenu } from "../../features/composer/ModelConfigMenu"
import { QuestionPickerCard } from "../../features/composer/QuestionPickerCard"
import { UsageRingButton } from "../../features/composer/UsageRingButton"
import type { ComposerAttachmentItem } from "../../features/composer/useComposerAttachments"
import { ComposerStatusLabel } from "../../features/session/SessionScreen"
import type { QuestionRequestInfo } from "../../lib/session-events"
import { cn } from "../../lib/cn"

export const Route = createFileRoute("/_shell/verify/chat-composer")({
  component: ChatComposerFixtureRoute
})

const transparentPixel =
  "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII="

const attachments: ComposerAttachmentItem[] = [
  {
    id: "failed",
    name: "very-long-session-recording-final-cut-v7.mov",
    mimeType: "video/quicktime",
    kind: "file",
    sizeBytes: 32_000_000,
    state: "failed",
    error: "Larger than 25 MB"
  },
  {
    id: "image",
    name: "screenshot.png",
    mimeType: "image/png",
    kind: "image",
    sizeBytes: 140_000,
    previewUrl: transparentPixel,
    state: "uploaded"
  },
  {
    id: "pdf",
    name: "proposal.pdf",
    mimeType: "application/pdf",
    kind: "file",
    sizeBytes: 340_000,
    previewUrl: transparentPixel,
    state: "uploading"
  }
]

const modelOption: SessionConfigOption = {
  id: "model",
  name: "Model",
  category: "model",
  currentValue: "opus",
  options: [
    { value: "opus", name: "Opus" },
    { value: "sonnet", name: "Sonnet" }
  ]
}

const thoughtLevelOption: SessionConfigOption = {
  id: "thinking",
  name: "Reasoning",
  category: "thought_level",
  currentValue: "high",
  options: [
    { value: "medium", name: "Medium" },
    { value: "high", name: "High" }
  ]
}

const speedOption: SessionConfigOption = {
  id: "speed",
  name: "Speed",
  category: "speed",
  currentValue: "fast",
  options: [
    { value: "fast", name: "Fast" },
    { value: "normal", name: "Normal" }
  ]
}

const questionRequest: QuestionRequestInfo = {
  questionId: "fixture-question",
  message: "The agent needs a choice before continuing.",
  questions: [
    {
      id: "approach",
      header: "Implementation",
      question: "How should the Tauri parity work proceed?",
      options: [
        {
          label: "Match macOS",
          description: "Use the native app as source of truth"
        },
        {
          label: "Keep web defaults",
          description: "Prefer existing browser behavior"
        }
      ],
      allowsOther: true
    }
  ]
}

const selectedQuestionOption = { approach: ["Match macOS"] }

const usageFixture = {
  used: 116_000,
  size: 128_000,
  costAmount: 0.12345,
  costCurrency: "USD"
}

function ToolbarChips({
  goalArmed = false,
  planOn = true,
  showAgent = true
}: {
  goalArmed?: boolean
  planOn?: boolean
  showAgent?: boolean
}) {
  return (
    <>
      <ModelConfigMenu
        modelOption={modelOption}
        thoughtLevelOption={thoughtLevelOption}
        speedOption={speedOption}
        onSelect={() => undefined}
      />
      {showAgent && (
        <ChipMenu
          label="Codex"
          title="Agent"
          icon={<Code2Icon className="size-3.5" />}
          selectedValue="codex"
          options={[
            { value: "codex", label: "Codex", icon: <Code2Icon className="size-3.5" /> },
            { value: "claude", label: "Claude" }
          ]}
          onSelect={() => undefined}
        />
      )}
      <button
        type="button"
        aria-label="Plan mode"
        aria-pressed={planOn}
        className={cn(
          "flex size-7 cursor-default items-center justify-center rounded-full outline-none",
          planOn
            ? "bg-primary/85 text-primary-foreground"
            : "text-muted-foreground hover:bg-primary/5"
        )}
      >
        <ListTodoIcon className="size-4" />
      </button>
      <button
        type="button"
        aria-label="Goal mode"
        aria-pressed={goalArmed}
        className={cn(
          "flex size-7 cursor-default items-center justify-center rounded-full outline-none",
          goalArmed
            ? "bg-primary/85 text-primary-foreground"
            : "text-muted-foreground hover:bg-primary/5"
        )}
      >
        <TargetIcon className="size-4" />
      </button>
    </>
  )
}

function ComposerFixture({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <section className="flex flex-col gap-2">
      <h2 className="text-muted-foreground text-xs font-semibold">{title}</h2>
      {children}
    </section>
  )
}

function NewChatAccessoryFixture() {
  return (
    <div className="flex items-center gap-3 rounded-b-2xl border border-t-0 border-[var(--herdman-card-border)] bg-[var(--herdman-card-bg)] px-3.5 pt-7 pb-2 text-sm">
      <ChipMenu
        label="Codex"
        title="Agent"
        icon={<Code2Icon className="size-3.5" />}
        selectedValue="codex"
        options={[
          { value: "codex", label: "Codex", icon: <Code2Icon className="size-3.5" /> },
          { value: "claude", label: "Claude" }
        ]}
        onSelect={() => undefined}
      />
      <ChipMenu
        label="Project directory"
        title="Where this chat's commands run"
        icon={<FolderIcon className="size-3.5 fill-current" />}
        selectedValue="project"
        options={[
          {
            value: "project",
            label: "Project directory",
            icon: <FolderIcon className="size-3.5 fill-current" />
          },
          { value: "worktree", label: "New worktree", icon: <GitBranchIcon className="size-3.5" /> }
        ]}
        onSelect={() => undefined}
      />
    </div>
  )
}

function ChatComposerFixtureRoute() {
  const [normalText, setNormalText] = useState("/")
  const [draftText, setDraftText] = useState("Follow up with the implementation details.")
  const [goalArmedText, setGoalArmedText] = useState("")
  const [goalText, setGoalText] = useState("Ship parity for composer states")
  const showsSelectedQuestion =
    typeof window !== "undefined" &&
    new URLSearchParams(window.location.search).get("selected") === "1"
  const attachmentsOnly =
    typeof window !== "undefined" &&
    new URLSearchParams(window.location.search).get("attachmentsOnly") === "1"
  const usageOnly =
    typeof window !== "undefined" &&
    new URLSearchParams(window.location.search).get("usageOnly") === "1"

  if (attachmentsOnly) {
    return (
      <div className="bg-background h-full overflow-auto">
        <div className="mx-auto flex w-full max-w-[760px] flex-col gap-4 px-6 pt-8 pb-8">
          <ComposerFixture title="Attachment composer">
            <Composer
              value=""
              onValueChange={() => undefined}
              attachments={attachments}
              usage={{ used: 62_000, size: 128_000, costAmount: 1.42, costCurrency: "USD" }}
              canSend
              chips={<ToolbarChips />}
              onSend={() => undefined}
              onAttachFiles={() => undefined}
              onRemoveAttachment={() => undefined}
              onRetryAttachment={() => undefined}
            />
          </ComposerFixture>
        </div>
      </div>
    )
  }

  if (usageOnly) {
    return (
      <div className="bg-background h-full overflow-auto">
        <div className="mx-auto flex w-full max-w-[760px] flex-col gap-4 px-6 pt-8 pb-8">
          <ComposerFixture title="Usage ring composer">
            <Composer
              value="Summarize the usage metrics once this finishes."
              onValueChange={() => undefined}
              usage={usageFixture}
              canSend
              chips={<ToolbarChips />}
              onSend={() => undefined}
              onAttachFiles={() => undefined}
            />
          </ComposerFixture>
          <ComposerFixture title="Usage popover">
            <div className="relative flex h-28 items-start px-2 pt-8">
              <UsageRingButton usage={usageFixture} forcePopover />
            </div>
          </ComposerFixture>
        </div>
      </div>
    )
  }

  return (
    <div className="bg-background h-full overflow-auto">
      <div className="mx-auto grid w-full max-w-[1180px] grid-cols-2 gap-4 px-6 pt-8 pb-8">
        <ComposerFixture title="Normal composer with attachments">
          <Composer
            value={normalText}
            onValueChange={setNormalText}
            commands={[
              { name: "review", description: "Review the current diff" },
              { name: "plan", description: "Draft a plan before editing" }
            ]}
            attachments={attachments}
            usage={{ used: 62_000, size: 128_000, costAmount: 1.42, costCurrency: "USD" }}
            canSend
            chips={<ToolbarChips />}
            onSend={() => undefined}
            onAttachFiles={() => undefined}
            onRemoveAttachment={() => undefined}
            onRetryAttachment={() => undefined}
          />
        </ComposerFixture>

        <ComposerFixture title="Agent running with draft">
          <Composer
            value={draftText}
            onValueChange={setDraftText}
            isSending
            canSend
            chips={<ToolbarChips />}
            onStop={() => undefined}
            onSend={() => undefined}
            onAttachFiles={() => undefined}
          />
        </ComposerFixture>

        <ComposerFixture title="Submitting handoff">
          <Composer
            value="Create a branch and inspect the failing test."
            onValueChange={() => undefined}
            isSending
            canSend
            chips={<ToolbarChips planOn={false} />}
            onSend={() => undefined}
            onAttachFiles={() => undefined}
          />
        </ComposerFixture>

        <ComposerFixture title="Goal armed mode">
          <Composer
            value={goalArmedText}
            onValueChange={setGoalArmedText}
            placeholder="Describe the goal"
            canSend={goalArmedText.trim() !== ""}
            chips={<ToolbarChips goalArmed />}
            onSend={() => undefined}
            onEscape={() => undefined}
          />
        </ComposerFixture>

        <ComposerFixture title="Goal edit mode">
          <Composer
            value={goalText}
            onValueChange={setGoalText}
            placeholder="Describe the goal"
            isGoalEditing
            canSend
            onEscape={() => undefined}
            onSend={() => undefined}
          />
          <ComposerStatusLabel message="An attachment failed to upload. Retry or remove it, then send again." />
        </ComposerFixture>

        <ComposerFixture title="New chat accessory strip">
          <div>
            <Composer
              value=""
              onValueChange={() => undefined}
              placeholder="Do anything"
              chips={<ToolbarChips showAgent={false} />}
              onSend={() => undefined}
              onAttachFiles={() => undefined}
            />
            <NewChatAccessoryFixture />
          </div>
        </ComposerFixture>

        <ComposerFixture title="Blocking question">
          <QuestionPickerCard
            request={questionRequest}
            initialSelections={showsSelectedQuestion ? selectedQuestionOption : undefined}
            onAnswer={() => undefined}
            onCancel={() => undefined}
          />
        </ComposerFixture>
      </div>
    </div>
  )
}
