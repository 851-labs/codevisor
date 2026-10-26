import AppKit

for argument in CommandLine.arguments.dropFirst() {
  guard let pid = pid_t(argument) else { continue }
  NSRunningApplication(processIdentifier: pid)?.unhide()
}
