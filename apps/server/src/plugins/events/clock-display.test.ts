import { describe, expect, it } from "vitest"

import { cronLabel } from "./clock-display.js"

describe("Clock schedule labels", () => {
  it.each([
    ["* * * * *", "Every min"],
    ["*/30 * * * *", "Every 30 mins"],
    ["*/20 * * * * *", "Every 20 secs"],
    ["0 * * * *", "Every hour"],
    ["5 * * * *", "Every hour at :05"],
    ["0 */2 * * *", "Every 2 hrs"],
    ["*/15 * * * 1-5", "Every 15 mins on weekdays"],
    ["0 15 * * 2", "Tuesdays at 3:00 PM"],
    ["30 9 * * 1,4", "Mondays and Thursdays at 9:30 AM"],
    ["0 9 * * 1,3,5", "Mondays, Wednesdays, and Fridays at 9:00 AM"],
    ["0 9 * * 1-5", "Weekdays at 9:00 AM"],
    ["0 10 * * 0,6", "Weekends at 10:00 AM"],
    ["0 0 * * *", "Daily at 12:00 AM"],
    ["0 9,17 * * *", "Daily at 9:00 AM and 5:00 PM"],
    ["0 9 1 * *", "Monthly on the 1st at 9:00 AM"],
    ["0 9 1,15 * *", "Monthly on the 1st and 15th at 9:00 AM"],
    ["0 9 22 * *", "Monthly on the 22nd at 9:00 AM"],
    ["0 9 * 1 *", 'On the cron schedule "0 9 * 1 *"'],
    ["7,19,43 */3 * * *", 'On the cron schedule "7,19,43 */3 * * *"']
  ])("reads %s as %s", (cron, label) => {
    expect(cronLabel(cron, "America/Los_Angeles")).toBe(label)
  })
})
