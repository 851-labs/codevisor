import { describe, expect, it } from "vitest"
import { hubLocationHint } from "../src/location-hint.js"

const geo = (continent: string, latitude?: number, longitude?: number): unknown => ({
  continent,
  ...(latitude === undefined ? {} : { latitude: String(latitude) }),
  ...(longitude === undefined ? {} : { longitude: String(longitude) })
})

describe("hubLocationHint", () => {
  it("splits North America along the Rockies and defaults east", () => {
    expect(hubLocationHint(geo("NA", 37.77, -122.42))).toBe("wnam") // San Francisco
    expect(hubLocationHint(geo("NA", 40.71, -74.01))).toBe("enam") // New York
    expect(hubLocationHint(geo("NA"))).toBe("enam") // no coordinates
  })

  it("hints South America honestly even though DOs spawn in enam today", () => {
    expect(hubLocationHint(geo("SA", -23.55, -46.63))).toBe("sam") // São Paulo
  })

  it("splits Europe at roughly Central Europe and defaults west", () => {
    expect(hubLocationHint(geo("EU", 48.86, 2.35))).toBe("weur") // Paris
    expect(hubLocationHint(geo("EU", 52.23, 21.01))).toBe("eeur") // Warsaw
    expect(hubLocationHint(geo("EU"))).toBe("weur") // no coordinates
  })

  it("separates the Middle East and Northeast/Southeast Asia", () => {
    expect(hubLocationHint(geo("AS", 25.2, 55.27))).toBe("me") // Dubai
    expect(hubLocationHint(geo("AS", 35.68, 139.69))).toBe("apac-ne") // Tokyo
    expect(hubLocationHint(geo("AS", 37.57, 126.98))).toBe("apac-ne") // Seoul
    expect(hubLocationHint(geo("AS", 1.35, 103.82))).toBe("apac-se") // Singapore
    expect(hubLocationHint(geo("AS", 28.61, 77.21))).toBe("apac-se") // Delhi: closer to apac-se
    expect(hubLocationHint(geo("AS"))).toBe("apac") // no coordinates
  })

  it("maps Oceania and Africa directly", () => {
    expect(hubLocationHint(geo("OC", -33.87, 151.21))).toBe("oc") // Sydney
    expect(hubLocationHint(geo("AF", 6.52, 3.38))).toBe("afr") // Lagos
  })

  it("returns no hint when geolocation is missing or unknown", () => {
    expect(hubLocationHint(undefined)).toBeUndefined()
    expect(hubLocationHint({})).toBeUndefined()
    expect(hubLocationHint(geo("T1"))).toBeUndefined() // Tor / unknown continent
  })
})
