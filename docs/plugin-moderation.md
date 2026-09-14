# Plugin moderation

Reports are stored in Cloud D1 (`plugin_reports`) before a Slack notification is
queued. Configure `PLUGIN_REPORT_SLACK_WEBHOOK` as a Worker secret with
`bunx wrangler secret put PLUGIN_REPORT_SLACK_WEBHOOK` from `apps/cloud`. Never
commit the webhook URL or pass it as a CLI argument. Failed notifications remain
pending and retry on the 15-minute cron. Delivery is at least once; use the report
ID to recognize duplicates. Reports require an account and are limited to 20 per
account per hour. Moderators should review incoming reports promptly.

Apply the Cloud D1 migrations before deploying the Worker. Deploy the website too
to publish the updated terms and the Apple association document. The production
iOS bundle (`com.dylanplayer.codevisor.ios`, team `C4M7D4G7LG`) needs Associated
Domains enabled in its signing profile. Confirm the App Store Connect age rating
is 16+ and reflects the app’s browser and other functionality.

## Manual moderation

Use D1 through an authorized account or agent. No admin UI or public moderation
write API exists. These examples are placeholders; replace the IDs deliberately.

```sql
-- Block one plugin on iOS.
INSERT INTO plugin_blocks (target_kind, target)
VALUES ('plugin', 'publisher.plugin');

-- Block a publisher on iOS, including future plugins in that namespace.
INSERT INTO plugin_blocks (target_kind, target)
VALUES ('publisher', 'publisher');

-- Reverse a restriction.
DELETE FROM plugin_blocks
WHERE target_kind = 'plugin' AND target = 'publisher.plugin';

-- Override an inaccurate publisher-declared rating.
INSERT INTO plugin_age_ratings (plugin_id, minimum_age)
VALUES ('publisher.plugin', 18)
ON CONFLICT(plugin_id) DO UPDATE SET minimum_age = excluded.minimum_age;

-- Review reports and notification delivery.
SELECT id, plugin_id, reason, details, created_at, notified_at
FROM plugin_reports ORDER BY created_at DESC;
```

The iOS catalog filters blocked plugins and publishers, including user-blocked
publishers. Install, review, and pane loading check the current policy. Visible
panes recheck every minute and when the app resumes. Policy failures prevent
loading. macOS retains the complete catalog and can install and open restricted
plugins. Removing a public GitHub topic still delists a repository everywhere.

iOS fetches the public catalog, plugin links, and moderation policy directly from
`https://cloud.codevisor.dev`, without account credentials. Changing the machine
discovery server cannot replace this catalog or bypass Codevisor's blocks. Debug
development runs use the runner's local Cloud service instead. Account consent,
personal publisher blocks, and reports remain on the account's configured Cloud
server. macOS continues to use its machine's catalog.

Publishers declare `ageRating` as 4, 9, 13, 16, or 18. iOS requires a declared
rating no higher than 16; missing ratings remain usable on macOS. The moderation
override takes priority. Publisher blocks use the plugin ID namespace, which
managed GitHub installs already verify against the repository owner.
The iOS plugin detail screen displays this effective age rating.

## Consent and links

Both native install screens name the plugin and explain its access. Consent is
recorded per Cloud account and source identity (a SHA-256 digest). Tapping an
installed plugin on iOS opens the same informational detail screen used by the
catalog. There is no separate consent review or backfill flow. Opening a plugin
does not require a stored consent record; iOS still checks the current moderation
policy, publisher blocks, and age rating.

Mac installs remain available while Cloud is offline. Consent waits locally for
delivery to the same account session.

`/plugins/index.json` includes public metadata and HTTPS plugin links.
`/api/plugins/index` is the authenticated account index for approved plugins,
including private/unlisted plugins; it excludes local paths and credentials.
HTTPS `/plugins/<id>` links enter the native detail/install flow. The public
website does not disclose private plugin metadata. Apple must assess the full
submission; these controls do not by themselves guarantee approval.
