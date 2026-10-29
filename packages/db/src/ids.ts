const UUID_SHAPE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
export const isUuid = (id: string): boolean => UUID_SHAPE.test(id)
export const canonicalUuid = (id: string): string => (isUuid(id) ? id.toLowerCase() : id)
