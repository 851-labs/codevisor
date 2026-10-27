CREATE TABLE `inbox` (
	`id` text PRIMARY KEY NOT NULL,
	`user_id` text NOT NULL,
	`plugin` text NOT NULL,
	`account_id` text NOT NULL,
	`ingress` text NOT NULL,
	`created_at` integer NOT NULL,
	FOREIGN KEY (`user_id`) REFERENCES `user`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE UNIQUE INDEX `inbox_user_target` ON `inbox` (`user_id`,`plugin`,`account_id`,`ingress`);--> statement-breakpoint
CREATE TABLE `oauth_flow` (
	`flow_id` text PRIMARY KEY NOT NULL,
	`user_id` text NOT NULL,
	`device_id` text NOT NULL,
	`expires_at` integer NOT NULL,
	FOREIGN KEY (`user_id`) REFERENCES `user`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE INDEX `oauth_flow_user_expires` ON `oauth_flow` (`user_id`,`expires_at`);