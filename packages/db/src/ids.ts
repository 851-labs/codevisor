/// UUIDs are case-insensitive identifiers, but they live in TEXT columns (and
/// in-memory maps) compared byte-wise — and clients disagree on rendering:
/// Swift's `UUID.uuidString` is uppercase, Node's `randomUUID()` lowercase.
/// Stored ids are canonically lowercase (createProject/createSession + the
/// "canonical lowercase uuid ids" migration); normalize uuid-shaped ids once
/// at the service boundary instead of `collate nocase` per query, which would
/// bypass the primary-key index. Non-uuid identifiers (harness ids, client
/// action tokens) pass through untouched.
const UUID_SHAPE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
export const canonicalUuid = (id: string): string => (UUID_SHAPE.test(id) ? id.toLowerCase() : id)
