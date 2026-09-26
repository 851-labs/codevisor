import { HttpFailure } from "../server-context.js"

/// Whether `labels` satisfies every `label=key=value` query parameter on
/// `url`. Repeated parameters must all match; a bare `label=key` matches any
/// value for that key.
export const matchesLabelFilters = (
  labels: Readonly<Record<string, string>> | undefined,
  url: URL
): boolean =>
  url.searchParams.getAll("label").every((filter) => {
    const separator = filter.indexOf("=")
    const key = separator === -1 ? filter : filter.slice(0, separator)
    if (key.length === 0) throw new HttpFailure(400, "label filters must look like key=value")
    const value = labels?.[key]
    return separator === -1 ? value !== undefined : value === filter.slice(separator + 1)
  })
