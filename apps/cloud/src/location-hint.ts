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
      return Number.isFinite(longitude) && longitude < -100 ? "wnam" : "enam"
    case "SA":
      return "sam"
    case "EU":
      return Number.isFinite(longitude) && longitude > 20 ? "eeur" : "weur"
    case "AS": {
      if (!Number.isFinite(longitude) || !Number.isFinite(latitude)) return "apac"
      if (longitude < 63) return "me"
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
