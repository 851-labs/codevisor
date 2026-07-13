# Chat notification delivery

Codevisor treats a completed turn and a turn blocked on user input as two
distinct attention events. Each event has a stable event id plus a session id,
server id, title, and kind (`finished` or `actionRequired`). Native alerts use
the event type as their title (for example, `Chat finished`) and the chat title
as their body, keeping the result glanceable without including agent output.

## Device-local presentation

The macOS client applies this policy at the moment an event arrives:

| Codevisor state           | Presentation                                               |
| ------------------------- | ---------------------------------------------------------- |
| Not active                | A native UserNotifications alert, using the selected sound |
| Active, another chat open | The selected `NSSound` only                                |
| Active, event's chat open | No interruption                                            |

Native alerts use the active interruption level. They remain subject to macOS
Focus, scheduled delivery, preview, and sound settings. Opening a chat removes
its delivered alerts. Tapping an alert activates Codevisor, switches to the
event's server when needed, and opens the chat.

Sound preferences are device-local. For native alerts, the chosen macOS sound
is copied into the app's `Library/Sounds` location so UserNotifications—not an
app-owned audio player—delivers it and continues to respect system policy.

## Multi-device delivery

Apple does not provide third-party apps with iMessage's private cross-device
notification arbitration. When an iOS client is added, Codevisor's server must
choose one primary device before using APNs; clients must not independently
push the same event to every registered device.

The server-side coordinator should retain the existing event shape and track:

- a stable installation id and APNs token per device;
- platform and notification capability;
- foreground/background state, active session id, and a short-lived presence
  heartbeat;
- last meaningful interaction time, used only when no device is foreground.

For each attention event, the coordinator should atomically choose one target:

1. If a foreground device is viewing that session, mark the event seen and do
   not notify anywhere.
2. Otherwise, if a device is foreground, send the live event only to that
   device. Its client plays the foreground sound.
3. Otherwise, send one APNs notification to the most recently active eligible
   device.
4. If presence is stale, fall back to the user's explicitly selected primary
   device, then to their most recently active device.

APNs payloads should use the event id for deduplication and the session id for
threading/collapse. Device acknowledgements must make the selection idempotent
so reconnects and retries cannot notify a second device. Focus and interruption
level remain system concerns on the selected device; chat completion and normal
questions are active, not Time Sensitive or Critical.
