CREATE TABLE `tunnel_endpoint` (
	`endpoint_id` text PRIMARY KEY NOT NULL,
	`user_id` text NOT NULL,
	`device_id` text NOT NULL,
	`kind` text NOT NULL,
	`updated_at` integer NOT NULL,
	FOREIGN KEY (`user_id`) REFERENCES `user`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE INDEX `tunnel_endpoint_user_device` ON `tunnel_endpoint` (`user_id`,`device_id`);