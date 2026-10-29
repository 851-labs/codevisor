import { reportAddress } from "../lib/plugin-catalog"
import { plainLinkClass } from "./site-page"

export function ReportLine({ href }: { href: string }) {
  return (
    <p className="mt-9 text-[13px] text-muted">
      Report a plugin:{" "}
      <a href={href} className={plainLinkClass}>
        {reportAddress}
      </a>
    </p>
  )
}
