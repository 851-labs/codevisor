const UUID_SHAPE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
export const canonicalUuid = (id: string): string => (UUID_SHAPE.test(id) ? id.toLowerCase() : id)
