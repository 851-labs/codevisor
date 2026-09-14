import { AppStoreConnectError, assignBuildToGroup, findBuild } from "./app-store-connect.mjs"

const reviewPending = new Set(["WAITING_FOR_REVIEW", "IN_REVIEW"])
const externalPending = new Set(["WAITING_FOR_BETA_REVIEW", "IN_BETA_REVIEW"])
const externalReady = new Set(["BETA_APPROVED", "READY_FOR_BETA_TESTING", "IN_BETA_TESTING"])

export function testFlightReleaseNotes(version, markdown, releaseURL) {
  if (!markdown.trim()) throw new Error("TestFlight release notes must not be empty.")
  const content = markdown
    .replace(/^# .+\n/m, "")
    .replace(/^## /gm, "")
    .replace(/ \(\[[a-f0-9]+\]\(https:\/\/github\.com\/[^\s)]+\)\)/g, "")
    .trim()
  const heading = `Codevisor ${version}\n\n`
  const footer = `\n\nFull release notes: ${releaseURL}`
  const budget = 4000 - heading.length - footer.length
  if (budget < 1) throw new Error("The TestFlight release notes URL is too long.")
  const truncated = content.length > budget
  let body = content.slice(0, truncated ? budget - 1 : budget)
  if (truncated) {
    // Avoid cutting a surrogate pair or a partly displayed changelog entry.
    const lineEnd = body.lastIndexOf("\n")
    body = lineEnd > 0 ? body.slice(0, lineEnd) : body.replace(/[\uD800-\uDBFF]$/, "")
    body += "…"
  }
  return `${heading}${body}${footer}`
}

export function validateBetaMetadata(review, localizations) {
  const missing = []
  for (const key of [
    "contactFirstName",
    "contactLastName",
    "contactEmail",
    "contactPhone",
    "notes"
  ])
    if (!review?.[key]?.trim()) missing.push(key)
  if (review?.demoAccountRequired !== true) missing.push("sign-in required")
  for (const key of ["demoAccountName", "demoAccountPassword"])
    if (!review?.[key]?.trim()) missing.push(key)
  if (!localizations.length) missing.push("beta app description")
  for (const localization of localizations)
    if (!localization.attributes.description?.trim())
      missing.push(`beta app description (${localization.attributes.locale})`)
  if (!localizations.some(({ attributes }) => attributes.feedbackEmail?.trim()))
    missing.push("feedback email")
  if (missing.length)
    throw new Error(
      `Complete TestFlight > Test Information in App Store Connect: ${missing.join(", ")}.`
    )
}

async function submissionForBuild(client, buildId) {
  const { data } = await client("betaAppReviewSubmissions", {
    query: { "filter[build]": buildId, limit: "200" }
  })
  if (data.length > 1) throw new Error("Multiple beta review submissions matched the build.")
  return data[0]
}

function requireReviewable(build, submission) {
  if (!build) throw new Error("The Alpha build has not been uploaded to TestFlight.")
  if (build.attributes.expired) throw new Error("The Alpha TestFlight build has expired.")
  if (build.attributes.buildAudienceType !== "APP_STORE_ELIGIBLE")
    throw new Error("The Alpha build is Internal Only. Create a new eligible Alpha build.")
  if (["FAILED", "INVALID"].includes(build.attributes.processingState))
    throw new Error(`Apple could not process the Alpha build: ${build.attributes.processingState}.`)
  if (build.attributes.processingState !== "VALID" || !build.betaDetail)
    throw new Error("The Alpha build is still processing. Rerun after it finishes.")
  const state = build.betaDetail.attributes.externalBuildState
  if (submission?.attributes.betaReviewState === "REJECTED" || state === "BETA_REJECTED")
    throw new Error("Apple rejected this beta. Resolve the rejection in App Store Connect first.")
  if (
    !externalPending.has(state) &&
    !externalReady.has(state) &&
    state !== "READY_FOR_BETA_SUBMISSION"
  )
    throw new Error(`The build cannot enter external testing: ${state ?? "unknown state"}.`)
  return state
}

async function saveNotes(client, buildId, locale, notes) {
  const { data } = await client("betaBuildLocalizations", {
    query: { "filter[build]": buildId, "filter[locale]": locale }
  })
  if (data.length > 1) throw new Error("Multiple TestFlight localizations matched the locale.")
  const existing = data[0]
  if (existing?.attributes.whatsNew === notes) return
  await client(existing ? `betaBuildLocalizations/${existing.id}` : "betaBuildLocalizations", {
    method: existing ? "PATCH" : "POST",
    body: {
      data: {
        type: "betaBuildLocalizations",
        ...(existing ? { id: existing.id } : {}),
        attributes: { whatsNew: notes, ...(existing ? {} : { locale }) },
        ...(existing ? {} : { relationships: { build: { data: { type: "builds", id: buildId } } } })
      }
    }
  })
}

async function ensureSubmission(client, buildId, existing) {
  if (existing) return existing
  try {
    const { data } = await client("betaAppReviewSubmissions", {
      method: "POST",
      body: {
        data: {
          type: "betaAppReviewSubmissions",
          relationships: { build: { data: { type: "builds", id: buildId } } }
        }
      }
    })
    return data
  } catch (error) {
    if (!(error instanceof AppStoreConnectError) || error.status !== 409) throw error
    // A previous attempt or another reviewer may have submitted the same build.
    // Do not retry unrelated conflicts such as Apple's review submission limit.
    const submitted = await submissionForBuild(client, buildId)
    if (
      !reviewPending.has(submitted?.attributes.betaReviewState) &&
      submitted?.attributes.betaReviewState !== "APPROVED"
    )
      throw error
    return submitted
  }
}

export async function promoteTestFlightBuild(
  client,
  configuration,
  { groupName = "Beta", locale = "en-US", notes, checkOnly = false, ...assignmentOptions } = {}
) {
  if (!groupName.trim()) throw new Error("An external TestFlight group name is required.")
  if (!notes?.trim() || notes.length > 4000)
    throw new Error("TestFlight notes must contain between 1 and 4000 characters.")
  const build = await findBuild(client, configuration)
  requireReviewable(build)
  const [review, localizations, groups, existingSubmission] = await Promise.all([
    client(`apps/${configuration.appId}/betaAppReviewDetail`),
    client(`apps/${configuration.appId}/betaAppLocalizations`, { query: { limit: "200" } }),
    client("betaGroups", {
      query: { "filter[app]": configuration.appId, "filter[name]": groupName }
    }),
    submissionForBuild(client, build.id)
  ])
  validateBetaMetadata(review.data?.attributes, localizations.data)
  requireReviewable(build, existingSubmission)
  if (groups.data.length > 1) throw new Error(`Multiple TestFlight groups are named ${groupName}.`)
  let group = groups.data[0]
  // Keep the existing group's identity when adopting the shorter default name.
  if (!group && groupName === "Beta") {
    const previous = await client("betaGroups", {
      query: { "filter[app]": configuration.appId, "filter[name]": "Public Beta" }
    })
    if (previous.data.length > 1)
      throw new Error("Multiple TestFlight groups are named Public Beta.")
    group = previous.data[0]
  }
  if (group && group.attributes.isInternalGroup !== false)
    throw new Error(`TestFlight group ${groupName} must be external.`)
  if (checkOnly)
    return { buildId: build.id, groupName, status: "checked", groupExists: Boolean(group) }

  const renamedGroupFrom =
    groupName === "Beta" && group?.attributes.name === "Public Beta"
      ? group.attributes.name
      : undefined
  if (renamedGroupFrom) {
    const { data } = await client(`betaGroups/${group.id}`, {
      method: "PATCH",
      body: {
        data: { type: "betaGroups", id: group.id, attributes: { name: groupName } }
      }
    })
    group = data
  }
  await saveNotes(client, build.id, locale, notes)
  if (!build.betaDetail.attributes.autoNotifyEnabled)
    await client(`buildBetaDetails/${build.betaDetail.id}`, {
      method: "PATCH",
      body: {
        data: {
          type: "buildBetaDetails",
          id: build.betaDetail.id,
          attributes: { autoNotifyEnabled: true }
        }
      }
    })
  if (!group) {
    const { data } = await client("betaGroups", {
      method: "POST",
      body: {
        data: {
          type: "betaGroups",
          attributes: {
            name: groupName,
            isInternalGroup: false,
            hasAccessToAllBuilds: false,
            publicLinkEnabled: false
          },
          relationships: { app: { data: { type: "apps", id: configuration.appId } } }
        }
      }
    })
    group = data
  }
  await assignBuildToGroup(client, build, group, assignmentOptions)
  // Group assignment may have started testing or advanced Apple's review state.
  const current = await findBuild(client, configuration)
  let submission = await submissionForBuild(client, build.id)
  const state = requireReviewable(current, submission)
  const result = {
    buildId: build.id,
    groupName,
    publicLink: group.attributes.publicLink ?? null,
    ...(renamedGroupFrom ? { renamedGroupFrom } : {})
  }
  if (state === "IN_BETA_TESTING") return { ...result, status: "testing" }
  if (externalReady.has(state)) {
    await client("buildBetaNotifications", {
      method: "POST",
      body: {
        data: {
          type: "buildBetaNotifications",
          relationships: { build: { data: { type: "builds", id: build.id } } }
        }
      }
    })
    return { ...result, status: "notified" }
  }
  if (!externalPending.has(state)) submission = await ensureSubmission(client, build.id, submission)
  if (submission?.attributes.betaReviewState === "REJECTED")
    throw new Error("Apple rejected this beta. Resolve the rejection in App Store Connect first.")
  return {
    ...result,
    status: submission?.attributes.betaReviewState === "APPROVED" ? "approved" : "submitted",
    reviewState: submission?.attributes.betaReviewState ?? state
  }
}
