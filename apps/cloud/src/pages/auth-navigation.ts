/** Auth may return only to a path on this Cloud instance. */
export const validAuthRedirect = (value: string): boolean =>
  value.startsWith("/") &&
  !value.startsWith("//") &&
  !value.includes("\\") &&
  ![...value].some((character) => character.charCodeAt(0) <= 32 || character.charCodeAt(0) === 127)

export const loginURL = (redirect: string, step = "sign-in"): string => {
  const query = new URLSearchParams({ redirect })
  if (step !== "sign-in") query.set("step", step)
  return `/login?${query}`
}
