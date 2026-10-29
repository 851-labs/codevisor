CREATE TABLE `inbox_route` (
	`inbox_id` text NOT NULL,
	`route` text NOT NULL,
	`route_key` text NOT NULL,
	`created_at` integer NOT NULL,
	PRIMARY KEY(`inbox_id`, `route`),
	FOREIGN KEY (`inbox_id`) REFERENCES `inbox`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE INDEX `inbox_route_lookup` ON `inbox_route` (`route`,`route_key`);