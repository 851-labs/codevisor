import { attempt } from "./errors.js"
import { blob, rowReader } from "./row-reader.js"
import type { ServiceContext } from "./service-context.js"
import type { CodevisorDatabaseService } from "./service.js"

export const maxStoredBrowserFavicons = 2000

export const makeBrowserFaviconService = ({
  sqlite
}: ServiceContext): Pick<CodevisorDatabaseService, "getBrowserFavicon" | "putBrowserFavicon"> => ({
  getBrowserFavicon: (sha256) =>
    attempt("getBrowserFavicon", () =>
      sqlite.transaction(() => {
        const data = faviconData(sqlite.prepare(faviconSql.read).get(sha256))
        if (data !== undefined) sqlite.prepare(faviconSql.touch).run(Date.now(), sha256)
        return data
      })()
    ),
  putBrowserFavicon: (sha256, data) =>
    attempt("putBrowserFavicon", () =>
      sqlite.transaction(() => {
        sqlite.prepare(faviconSql.upsert).run(sha256, data, Date.now())
        sqlite.prepare(faviconSql.prune).run(maxStoredBrowserFavicons)
      })()
    )
})

const faviconRows = rowReader({ data: blob })

const faviconData = (row: unknown): Buffer | undefined => faviconRows.maybe(row)?.data

const faviconSql = {
  read: "select data from browser_favicons where sha256 = ?",
  touch: "update browser_favicons set used_at = ? where sha256 = ?",
  upsert: `insert into browser_favicons (sha256, data, used_at) values (?, ?, ?)
           on conflict(sha256) do update set used_at = excluded.used_at`,
  prune: `delete from browser_favicons where sha256 not in
            (select sha256 from browser_favicons order by used_at desc limit ?)`
}
