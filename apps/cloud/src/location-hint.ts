/// Best-effort Durable Object placement hint derived from a request's
/// Cloudflare geolocation (`request.cf`).
///
/// A `UserHub` is materialized by the FIRST request that references it and
/// lives in that colo for its lifetime — location hints are ignored on every
/// call after creation. So every hub access passes a hint derived from the
/// caller's location: whoever touches an account first pulls its hub to their
/// side of the world, instead of leaving placement to Cloudflare's default
/// (which can strand a hub an ocean away from both the user and their
/// machines, doubling every relay frame's round trip).
///
/// Note: Cloudflare does not yet run Durable Objects in every hinted region —
/// "sam" and "afr" currently spawn in the nearest supported region instead
/// (see https://developers.cloudflare.com/durable-objects/reference/data-location/).
/// Passing the honest hint is still correct: when coverage expands, placement
/// improves with no code change here.

/// The subset of `request.cf` this module reads. Cloudflare serializes
/// latitude/longitude as strings.
interface RequestGeo {
  readonly continent?: string
  readonly latitude?: string
  readonly longitude?: string
}

export const hubLocationHint = (cf: unknown): DurableObjectLocationHint | undefined => {
  const geo = (cf ?? {}) as RequestGeo
  const longitude = Number(geo.longitude)
  const latitude = Number(geo.latitude)
  switch (geo.continent) {
    case "NA":
      // Split roughly along the Rockies; unknown longitude defaults east.
      return Number.isFinite(longitude) && longitude < -100 ? "wnam" : "enam"
    case "SA":
      return "sam"
    case "EU":
      // Split roughly at Central Europe; unknown longitude defaults west.
      return Number.isFinite(longitude) && longitude > 20 ? "eeur" : "weur"
    case "AS": {
      if (!Number.isFinite(longitude) || !Number.isFinite(latitude)) return "apac"
      // Middle East sits west of ~63°E within Cloudflare's AS continent.
      if (longitude < 63) return "me"
      // Northeast Asia (Japan/Korea/northern China) vs. the rest of APAC
      // (Southeast Asia and the subcontinent, which route better via apac-se).
      return latitude >= 27 && longitude >= 100 ? "apac-ne" : "apac-se"
    }
    case "OC":
      return "oc"
    case "AF":
      return "afr"
    default:
      return undefined
  }
}
