import {
  browserCookieKey,
  shareableBrowserURL,
  type BrowserCookieSnapshot,
  type BrowserNavigation
} from "@codevisor/api"
import { attempt } from "./errors.js"
import type { CodevisorDatabaseService } from "./service.js"
import type { ServiceContext } from "./service-context.js"

export const makeBrowserStateService = ({
  sqlite
}: ServiceContext): Pick<
  CodevisorDatabaseService,
  "exchangeBrowserCookies" | "getBrowserNavigation" | "setBrowserNavigation"
> => {
  const read = <T>(key: string): T | undefined => {
    const row = sqlite.prepare("select value from instance_meta where key = ?").get(key) as
      | { value: string }
      | undefined
    return row ? (JSON.parse(row.value) as T) : undefined
  }
  const write = (key: string, value: unknown) =>
    sqlite
      .prepare(
        "insert into instance_meta (key, value) values (?, ?) on conflict(key) do update set value = excluded.value"
      )
      .run(key, JSON.stringify(value))
  return {
    exchangeBrowserCookies: (mutations) =>
      attempt("exchangeBrowserCookies", () =>
        sqlite.transaction(() => {
          if (mutations.length > 20_000) throw new Error("Too many cookie changes")
          const current = read<BrowserCookieSnapshot>("browser-cookies-v1") ?? {
            revision: 0,
            entries: []
          }
          const entries = new Map(current.entries.map((entry) => [entry.key, entry]))
          let revision = current.revision
          const now = Date.now() / 1000
          for (const entry of entries.values()) {
            if (entry.cookie?.expires !== undefined && entry.cookie.expires <= now) {
              entries.set(entry.key, { key: entry.key, revision: ++revision, cookie: null })
            }
          }
          for (const mutation of mutations) {
            const { cookie, key, expectedRevision } = mutation
            if (
              key.length > 8192 ||
              !Number.isSafeInteger(expectedRevision) ||
              expectedRevision < 0
            )
              throw new Error("Invalid cookie revision or key")
            if (
              cookie &&
              (browserCookieKey(cookie) !== key ||
                !cookie.domain ||
                !cookie.path.startsWith("/") ||
                cookie.name.length + cookie.value.length > 16_384 ||
                /[\r\n\0]/.test(cookie.domain))
            )
              throw new Error("Invalid cookie")
            const previous = entries.get(key)
            // A stale client must not resurrect a logout or overwrite a newer login.
            if ((previous?.revision ?? 0) !== expectedRevision) continue
            if (previous && JSON.stringify(previous.cookie) === JSON.stringify(cookie)) continue
            entries.set(key, { key, revision: ++revision, cookie })
          }
          const snapshot = { revision, entries: [...entries.values()] }
          if (revision !== current.revision) write("browser-cookies-v1", snapshot)
          return snapshot
        })()
      ),
    getBrowserNavigation: (paneId) =>
      attempt("getBrowserNavigation", () =>
        read<BrowserNavigation>(`browser-navigation:${paneId}`)
      ),
    setBrowserNavigation: (paneId, navigation) =>
      attempt("setBrowserNavigation", () => {
        if (!shareableBrowserURL(navigation.url)) return
        write(`browser-navigation:${paneId}`, {
          url: navigation.url,
          title: navigation.title.slice(0, 512)
        })
      })
  }
}
