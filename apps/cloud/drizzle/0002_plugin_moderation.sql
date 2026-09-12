CREATE TABLE `plugin_age_ratings` (
	`plugin_id` text PRIMARY KEY NOT NULL,
	`minimum_age` integer NOT NULL,
	CONSTRAINT "plugin_age_values" CHECK("plugin_age_ratings"."minimum_age" IN (4, 9, 13, 16, 18))
);
--> statement-breakpoint
CREATE TABLE `plugin_blocks` (
	`target_kind` text NOT NULL,
	`target` text NOT NULL,
	`reason` text DEFAULT 'This plugin is unavailable on iOS.' NOT NULL,
	`created_at` integer DEFAULT (unixepoch() * 1000) NOT NULL,
	PRIMARY KEY(`target_kind`, `target`),
	CONSTRAINT "plugin_blocks_kind" CHECK("plugin_blocks"."target_kind" IN ('plugin', 'publisher'))
);
--> statement-breakpoint
CREATE TABLE `plugin_consents` (
	`user_id` text NOT NULL,
	`plugin_id` text NOT NULL,
	`consent_key` text NOT NULL,
	`notice_version` integer NOT NULL,
	`created_at` integer NOT NULL,
	PRIMARY KEY(`user_id`, `plugin_id`, `consent_key`),
	FOREIGN KEY (`user_id`) REFERENCES `user`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE TABLE `plugin_publisher_blocks` (
	`user_id` text NOT NULL,
	`publisher` text NOT NULL,
	`created_at` integer NOT NULL,
	PRIMARY KEY(`user_id`, `publisher`),
	FOREIGN KEY (`user_id`) REFERENCES `user`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE TABLE `plugin_reports` (
	`id` text PRIMARY KEY NOT NULL,
	`user_id` text,
	`plugin_id` text NOT NULL,
	`plugin_name` text NOT NULL,
	`reason` text NOT NULL,
	`details` text DEFAULT '' NOT NULL,
	`created_at` integer NOT NULL,
	`notified_at` integer,
	FOREIGN KEY (`user_id`) REFERENCES `user`(`id`) ON UPDATE no action ON DELETE set null
);
--> statement-breakpoint
CREATE INDEX `plugin_reports_pending` ON `plugin_reports` (`notified_at`,`created_at`);--> statement-breakpoint
CREATE INDEX `plugin_reports_user_time` ON `plugin_reports` (`user_id`,`created_at`);