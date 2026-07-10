import type { AttachmentRef } from "@herdman/api"
import {
  DownloadIcon,
  FileIcon,
  ImageIcon,
  LoaderCircleIcon,
  MinusIcon,
  PaperclipIcon,
  PlusIcon,
  XIcon
} from "lucide-react"
import {
  type KeyboardEvent as ReactKeyboardEvent,
  type ReactNode,
  useEffect,
  useState
} from "react"

import { cn } from "../../lib/cn"
import { useApi } from "../../lib/api"

export interface AttachmentPreviewInfo {
  fileId?: string
  name: string
  mimeType: string
  kind: "image" | "file"
  sizeBytes: number
}

export interface LightboxItem {
  name: string
  mimeType: string
  url?: string
  fileId?: string
}

export function isPdfAttachment(attachment: Pick<AttachmentPreviewInfo, "mimeType" | "name">) {
  return attachment.mimeType === "application/pdf" || attachment.name.toLowerCase().endsWith(".pdf")
}

export function hasVisualAttachmentPreview(attachment: AttachmentPreviewInfo) {
  return attachment.kind === "image" || isPdfAttachment(attachment)
}

export function AttachmentLightbox({ item, onClose }: { item: LightboxItem; onClose: () => void }) {
  const { client } = useApi()
  const [objectUrl, setObjectUrl] = useState<string | undefined>(item.url)
  const [loadFailed, setLoadFailed] = useState(false)
  const [zoom, setZoom] = useState(1)

  useEffect(() => {
    let revokedUrl: string | undefined
    let cancelled = false
    setZoom(1)
    setLoadFailed(false)
    setObjectUrl(item.url)

    if (item.url == null && item.fileId != null) {
      void client
        .downloadFile(item.fileId)
        .then((blob) => {
          if (cancelled) return
          const next = URL.createObjectURL(blob)
          revokedUrl = next
          setObjectUrl(next)
        })
        .catch(() => {
          if (!cancelled) setLoadFailed(true)
        })
    }

    return () => {
      cancelled = true
      if (revokedUrl != null) URL.revokeObjectURL(revokedUrl)
    }
  }, [client, item.fileId, item.url])

  useEffect(() => {
    const handler = (event: KeyboardEvent) => {
      if (event.key === "Escape") {
        event.preventDefault()
        onClose()
      }
    }
    window.addEventListener("keydown", handler)
    return () => window.removeEventListener("keydown", handler)
  }, [onClose])

  const clampedZoom = Math.min(5, Math.max(0.1, zoom))

  const download = async () => {
    if (objectUrl != null) {
      downloadUrl(objectUrl, item.name)
      return
    }
    if (item.fileId == null) return
    try {
      const blob = await client.downloadFile(item.fileId)
      const next = URL.createObjectURL(blob)
      downloadUrl(next, item.name)
      window.setTimeout(() => URL.revokeObjectURL(next), 0)
    } catch {
      setLoadFailed(true)
    }
  }

  return (
    <div
      className="fixed inset-0 z-50 flex bg-black/90 text-white"
      role="dialog"
      aria-label={`Attachment viewer, ${item.name}`}
      onClick={onClose}
    >
      <div className="absolute top-5 right-5 z-10 flex gap-2">
        <LightboxButton label="Download" onClick={download}>
          <DownloadIcon className="size-4" />
        </LightboxButton>
        <LightboxButton label="Close" onClick={onClose}>
          <XIcon className="size-4" />
        </LightboxButton>
      </div>
      <div
        className="herdman-scrollbar min-h-0 flex-1 overflow-auto"
        onClick={(event) => event.stopPropagation()}
      >
        {objectUrl != null ? (
          <div
            className="flex min-h-full min-w-full items-center justify-center p-12"
            style={lightboxCanvasSize(clampedZoom)}
          >
            {isPdfAttachment(item) ? (
              <iframe
                src={objectUrl}
                title={item.name}
                className="h-[calc(100vh-6rem)] w-[min(64rem,calc(100vw-6rem))] shrink-0 rounded-lg border border-white/15 bg-white"
                style={{ transform: `scale(${clampedZoom})` }}
              />
            ) : (
              <img
                src={objectUrl}
                alt={item.name}
                className="max-h-[calc(100vh-6rem)] max-w-[calc(100vw-6rem)] shrink-0 object-contain"
                style={{ transform: `scale(${clampedZoom})` }}
                draggable={false}
              />
            )}
          </div>
        ) : loadFailed ? (
          <div className="flex min-h-full flex-col items-center justify-center gap-2 text-white/70">
            <ImageIcon className="size-9" />
            <p>This attachment is no longer available.</p>
          </div>
        ) : (
          <div className="flex min-h-full items-center justify-center">
            <LoaderCircleIcon className="size-7 animate-spin text-white/70" />
          </div>
        )}
      </div>
      <div className="absolute bottom-5 left-1/2 flex -translate-x-1/2 items-center gap-1 rounded-full bg-white/14 px-3 py-1.5 text-sm shadow-lg ring-1 ring-white/15 backdrop-blur">
        <LightboxButton label="Zoom out" onClick={() => setZoom((value) => value - 0.25)}>
          <MinusIcon className="size-4" />
        </LightboxButton>
        <span className="min-w-12 text-center font-mono">{Math.round(clampedZoom * 100)}%</span>
        <LightboxButton label="Zoom in" onClick={() => setZoom((value) => value + 0.25)}>
          <PlusIcon className="size-4" />
        </LightboxButton>
      </div>
    </div>
  )
}

export function lightboxCanvasSize(zoom: number) {
  const canvasScale = Math.max(1, zoom)
  return {
    width: `${canvasScale * 100}%`,
    height: `${canvasScale * 100}%`
  }
}

export function RemoteAttachmentThumb({ attachment }: { attachment: AttachmentRef }) {
  const { client } = useApi()
  const [objectUrl, setObjectUrl] = useState<string>()
  const [lightboxItem, setLightboxItem] = useState<LightboxItem>()
  const visual = hasVisualAttachmentPreview(attachment)

  useEffect(() => {
    if (!visual) return
    let revokedUrl: string | undefined
    let cancelled = false
    void client
      .downloadFile(attachment.fileId)
      .then((blob) => {
        if (cancelled) return
        const next = URL.createObjectURL(blob)
        revokedUrl = next
        setObjectUrl(next)
      })
      .catch(() => undefined)
    return () => {
      cancelled = true
      if (revokedUrl != null) URL.revokeObjectURL(revokedUrl)
    }
  }, [attachment.fileId, client, visual])

  const open = () => {
    if (visual) {
      setLightboxItem({
        fileId: attachment.fileId,
        mimeType: attachment.mimeType,
        name: attachment.name,
        url: objectUrl
      })
      return
    }
    void client.downloadFile(attachment.fileId).then((blob) => {
      const next = URL.createObjectURL(blob)
      downloadUrl(next, attachment.name)
      window.setTimeout(() => URL.revokeObjectURL(next), 0)
    })
  }

  return (
    <>
      {visual ? (
        <VisualThumb
          name={attachment.name}
          isPdf={isPdfAttachment(attachment)}
          imageUrl={objectUrl}
          onClick={open}
        />
      ) : (
        <FileChip name={attachment.name} onClick={open} />
      )}
      {lightboxItem != null && (
        <AttachmentLightbox item={lightboxItem} onClose={() => setLightboxItem(undefined)} />
      )}
    </>
  )
}

export function VisualThumb({
  name,
  isPdf,
  imageUrl,
  onClick,
  overlay,
  className
}: {
  name: string
  isPdf: boolean
  imageUrl?: string
  onClick?: () => void
  overlay?: ReactNode
  className?: string
}) {
  const handleKeyDown = (event: ReactKeyboardEvent<HTMLDivElement>) => {
    if (event.key !== "Enter" && event.key !== " ") return
    event.preventDefault()
    onClick?.()
  }

  return (
    <div
      role="button"
      tabIndex={0}
      aria-label={`Attachment ${name}`}
      title={name}
      onClick={onClick}
      onKeyDown={handleKeyDown}
      className={cn(
        "relative size-14 shrink-0 cursor-default overflow-hidden rounded-lg border border-[var(--herdman-separator)] bg-bubble outline-none",
        className
      )}
    >
      {imageUrl != null ? (
        isPdf ? (
          <object
            data={imageUrl}
            type="application/pdf"
            aria-label=""
            className="pointer-events-none size-full object-cover"
          >
            <div className="flex size-full items-center justify-center">
              <ImageIcon className="text-muted-foreground size-5" />
            </div>
          </object>
        ) : (
          <img src={imageUrl} alt="" className="size-full object-cover" draggable={false} />
        )
      ) : (
        <div className="flex size-full items-center justify-center">
          <ImageIcon className="text-muted-foreground size-5" />
        </div>
      )}
      {isPdf && <PdfBadge />}
      {overlay}
    </div>
  )
}

export function FileChip({ name, onClick }: { name: string; onClick?: () => void }) {
  const longName = name.length > 24
  const className = cn(
    "flex h-14 max-w-[200px] items-center gap-1.5 overflow-hidden rounded-lg border border-[var(--herdman-separator)] bg-bubble px-2.5 text-sm outline-none",
    onClick != null && "cursor-default hover:bg-[var(--herdman-card-hover-bg)]",
    longName && "w-[200px]"
  )
  const content = (
    <>
      <FileIcon className="text-muted-foreground size-4 shrink-0" />
      <MiddleTruncatedName name={name} />
    </>
  )

  if (onClick == null) {
    return (
      <div title={name} className={className}>
        {content}
      </div>
    )
  }

  return (
    <button type="button" title={name} onClick={onClick} className={className}>
      {content}
    </button>
  )
}

function MiddleTruncatedName({ name }: { name: string }) {
  const { base, suffix } = splitFileNameForTruncation(name)

  return (
    <span className="flex min-w-0 flex-1 text-left">
      <span className="min-w-0 truncate">{base}</span>
      {suffix !== "" && <span className="shrink-0">{suffix}</span>}
    </span>
  )
}

function splitFileNameForTruncation(name: string) {
  const dotIndex = name.lastIndexOf(".")
  if (dotIndex <= 0 || dotIndex === name.length - 1) return { base: name, suffix: "" }
  return { base: name.slice(0, dotIndex), suffix: name.slice(dotIndex) }
}

export function PdfBadge() {
  return (
    <span className="absolute bottom-1 left-1 rounded bg-black/60 px-1 py-0.5 text-[8px] leading-none font-bold text-white">
      PDF
    </span>
  )
}

export function DropToAttachOverlay() {
  return (
    <div className="pointer-events-none absolute inset-0 z-30 flex items-center justify-center bg-background/92">
      <div className="absolute inset-4 rounded-2xl border-2 border-dashed border-[var(--herdman-accent)]/80" />
      <div className="flex flex-col items-center gap-2.5">
        <PaperclipIcon className="text-muted-foreground size-[30px]" strokeWidth={2} />
        <span className="text-2xl font-semibold">Drop to attach</span>
      </div>
    </div>
  )
}

function LightboxButton({
  label,
  onClick,
  children
}: {
  label: string
  onClick: () => void
  children: ReactNode
}) {
  return (
    <button
      type="button"
      aria-label={label}
      title={label}
      onClick={(event) => {
        event.stopPropagation()
        onClick()
      }}
      className="flex size-8 items-center justify-center rounded-full bg-white/14 text-white outline-none ring-1 ring-white/15 backdrop-blur hover:bg-white/20"
    >
      {children}
    </button>
  )
}

function downloadUrl(url: string, name: string) {
  const anchor = document.createElement("a")
  anchor.href = url
  anchor.download = name
  document.body.append(anchor)
  anchor.click()
  anchor.remove()
}
