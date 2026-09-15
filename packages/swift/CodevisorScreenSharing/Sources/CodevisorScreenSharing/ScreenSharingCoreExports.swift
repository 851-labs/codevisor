/// The media package re-exports its WebRTC-free foundation so every existing
/// `import CodevisorScreenSharing` keeps seeing frames, the mailbox, metrics and
/// the message types. New backends import `ScreenSharingCore` directly.
@_exported import ScreenSharingCore
