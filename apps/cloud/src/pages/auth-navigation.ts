export const validAuthRedirect = (value: string): boolean =>
  value.startsWith("/") &&
  !value.startsWith("//") &&
  !value.includes("\\") &&
  !value
    .split("")
    .some((character) => character.charCodeAt(0) <= 32 || character.charCodeAt(0) === 127)

export const loginURL = (redirect: string, step = "sign-in"): string => {
  const query = new URLSearchParams({ redirect })
  if (step !== "sign-in") query.set("step", step)
  return `/login?${query.toString()}`
}
