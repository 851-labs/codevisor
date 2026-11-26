export const recordSentryInstallation = async (
  db: D1Database,
  uuid: string,
  organizationId: string
): Promise<void> => {
  await db.prepare(installationSql.record).bind(uuid, organizationId, Date.now()).run()
}

export const forgetSentryInstallation = async (db: D1Database, uuid: string): Promise<void> => {
  await db.prepare(installationSql.forget).bind(uuid).run()
}

export const sentryInstallationOrganization = async (
  db: D1Database,
  uuid: string
): Promise<string | undefined> =>
  (await db.prepare(installationSql.organization).bind(uuid).first<OrganizationRow>())
    ?.organization_id ?? undefined

interface OrganizationRow {
  organization_id: string
}

const installationSql = {
  record: `INSERT INTO sentry_installation (uuid, organization_id, created_at) VALUES (?, ?, ?)
     ON CONFLICT(uuid) DO UPDATE SET organization_id = excluded.organization_id`,
  forget: "DELETE FROM sentry_installation WHERE uuid = ?",
  organization: "SELECT organization_id FROM sentry_installation WHERE uuid = ?"
}
