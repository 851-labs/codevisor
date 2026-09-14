-- Keep the newest outstanding challenge per identifier before enforcing rotation.
DELETE FROM verification WHERE rowid NOT IN (
  SELECT rowid FROM (
    SELECT rowid, ROW_NUMBER() OVER (PARTITION BY identifier ORDER BY created_at DESC, rowid DESC) AS position
    FROM verification
  ) WHERE position = 1
);
--> statement-breakpoint
DROP INDEX `verification_identifier_idx`;--> statement-breakpoint
CREATE UNIQUE INDEX `verification_identifier_idx` ON `verification` (`identifier`);