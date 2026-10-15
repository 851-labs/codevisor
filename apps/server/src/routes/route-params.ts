export const routeParam = (params: Readonly<Record<string, string>>, name: string): string => {
  const value = params[name]
  if (value === undefined) throw new Error(`Route parameter ${name} is missing`)
  return value
}
