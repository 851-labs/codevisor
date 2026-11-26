CREATE TABLE `sentry_installation` (
	`uuid` text PRIMARY KEY NOT NULL,
	`organization_id` text NOT NULL,
	`created_at` integer NOT NULL
);
--> statement-breakpoint
CREATE TABLE `__new_inbox_route` (
	`inbox_id` text NOT NULL,
	`route` text NOT NULL,
	`route_key` text NOT NULL,
	`created_at` integer NOT NULL,
	PRIMARY KEY(`inbox_id`, `route`, `route_key`),
	FOREIGN KEY (`inbox_id`) REFERENCES `inbox`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
INSERT INTO `__new_inbox_route`("inbox_id", "route", "route_key", "created_at") SELECT "inbox_id", "route", "route_key", "created_at" FROM `inbox_route`;--> statement-breakpoint
DROP TABLE `inbox_route`;--> statement-breakpoint
ALTER TABLE `__new_inbox_route` RENAME TO `inbox_route`;--> statement-breakpoint
CREATE INDEX `inbox_route_lookup` ON `inbox_route` (`route`,`route_key`);