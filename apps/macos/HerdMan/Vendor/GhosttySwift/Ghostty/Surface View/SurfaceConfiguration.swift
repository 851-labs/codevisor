// HERDMAN-PATCH-BEGIN: file extracted from upstream SurfaceView.swift.
// Upstream defines these members inside `extension Ghostty` in
// macos/Sources/Ghostty/Surface View/SurfaceView.swift:
//   - struct SurfaceConfiguration: L627-752 (verbatim)
//   - static func moveFocus(to:from:delay:): L1136-1190 (verbatim)
// The rest of that file is the SwiftUI wrapper layer (Ghostty.Terminal,
// InspectableSurface, KeyStateIndicator, environment keys, ...) which HerdMan
// replaces with its own NSViewRepresentable (TerminalSurfaceView.swift), so
// only these two members are vendored.
// HERDMAN-PATCH-END
import SwiftUI
import System
import GhosttyKit

extension Ghostty {
    /// The configuration for a surface. For any configuration not set, defaults will be chosen from
    /// libghostty, usually from the Ghostty configuration.
    struct SurfaceConfiguration {
        /// Explicit font size to use in points
        var fontSize: Float32?

        /// Explicit working directory. This is normalized on assignment to
        /// remove any redundant and trailing path separators.
        var workingDirectory: String? {
            get { normalizedWorkingDirectory }
            set { normalizedWorkingDirectory = newValue.map { FilePath($0).string } }
        }
        private var normalizedWorkingDirectory: String?

        /// Explicit command to set
        var command: String?

        /// Environment variables to set for the terminal
        var environmentVariables: [String: String] = [:]

        /// Extra input to send as stdin
        var initialInput: String?

        /// Wait after the command
        var waitAfterCommand: Bool = false

        /// Context for surface creation
        var context: ghostty_surface_context_e = GHOSTTY_SURFACE_CONTEXT_WINDOW

        init() {}

        init(from config: ghostty_surface_config_s) {
            self.fontSize = config.font_size
            if let workingDirectory = config.working_directory {
                self.workingDirectory = String.init(cString: workingDirectory, encoding: .utf8)
            }
            if let command = config.command {
                self.command = String.init(cString: command, encoding: .utf8)
            }

            // Convert the C env vars to Swift dictionary
            if config.env_var_count > 0, let envVars = config.env_vars {
                for i in 0..<config.env_var_count {
                    let envVar = envVars[i]
                    if let key = String(cString: envVar.key, encoding: .utf8),
                       let value = String(cString: envVar.value, encoding: .utf8) {
                        self.environmentVariables[key] = value
                    }
                }
            }
            self.context = config.context
        }

        /// Provides a C-compatible ghostty configuration within a closure. The configuration
        /// and all its string pointers are only valid within the closure.
        func withCValue<T>(view: SurfaceView, _ body: (inout ghostty_surface_config_s) throws -> T) rethrows -> T {
            var config = ghostty_surface_config_new()
            config.userdata = Unmanaged.passUnretained(view).toOpaque()
#if os(macOS)
            config.platform_tag = GHOSTTY_PLATFORM_MACOS
            config.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(
                nsview: Unmanaged.passUnretained(view).toOpaque()
            ))
            config.scale_factor = NSScreen.main!.backingScaleFactor
#elseif os(iOS)
            config.platform_tag = GHOSTTY_PLATFORM_IOS
            config.platform = ghostty_platform_u(ios: ghostty_platform_ios_s(
                uiview: Unmanaged.passUnretained(view).toOpaque()
            ))
            // Note that UIScreen.main is deprecated and we're supposed to get the
            // screen through the view hierarchy instead. This means that we should
            // probably set this to some default, then modify the scale factor through
            // libghostty APIs when a UIView is attached to a window/scene. TODO.
            config.scale_factor = UIScreen.main.scale
#else
#error("unsupported target")
#endif

            // Zero is our default value that means to inherit the font size.
            config.font_size = fontSize ?? 0

            // Set wait after command
            config.wait_after_command = waitAfterCommand

            // Set context
            config.context = context

            // Use withCString to ensure strings remain valid for the duration of the closure
            return try workingDirectory.withCString { cWorkingDir in
                config.working_directory = cWorkingDir

                return try command.withCString { cCommand in
                    config.command = cCommand

                    return try initialInput.withCString { cInput in
                        config.initial_input = cInput

                        // Convert dictionary to arrays for easier processing
                        let keys = Array(environmentVariables.keys)
                        let values = Array(environmentVariables.values)

                        // Create C strings for all keys and values
                        return try keys.withCStrings { keyCStrings in
                            return try values.withCStrings { valueCStrings in
                                // Create array of ghostty_env_var_s
                                var envVars = [ghostty_env_var_s]()
                                envVars.reserveCapacity(environmentVariables.count)
                                for i in 0..<environmentVariables.count {
                                    envVars.append(ghostty_env_var_s(
                                        key: keyCStrings[i],
                                        value: valueCStrings[i]
                                    ))
                                }

                                return try envVars.withUnsafeMutableBufferPointer { buffer in
                                    config.env_vars = buffer.baseAddress
                                    config.env_var_count = environmentVariables.count
                                    return try body(&config)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    #if canImport(AppKit)
    /// When changing the split state, or going full screen (native or non), the terminal view
    /// will lose focus. There has to be some nice SwiftUI-native way to fix this but I can't
    /// figure it out so we're going to do this hacky thing to bring focus back to the terminal
    /// that should have it.
    static func moveFocus(
        to: SurfaceView,
        from: SurfaceView? = nil,
        delay: TimeInterval? = nil
    ) {
        // The whole delay machinery is a bit of a hack to work around a
        // situation where the window is destroyed and the surface view
        // will never be attached to a window. Realistically, we should
        // handle this upstream but we also don't want this function to be
        // a source of infinite loops.

        // Our max delay before we give up
        let maxDelay: TimeInterval = 0.5
        guard (delay ?? 0) < maxDelay else { return }

        // We start at a 50 millisecond delay and do a doubling backoff
        let nextDelay: TimeInterval = if let delay {
            delay * 2
        } else {
            // 100 milliseconds
            0.05
        }

        let work: DispatchWorkItem = .init {
            // If the callback runs before the surface is attached to a view
            // then the window will be nil. We just reschedule in that case.
            guard let window = to.window else {
                moveFocus(to: to, from: from, delay: nextDelay)
                return
            }

            // If we had a previously focused node and its not where we're sending
            // focus, make sure that we explicitly tell it to lose focus. In theory
            // we should NOT have to do this but the focus callback isn't getting
            // called for some reason.
            if let from = from {
                _ = from.resignFirstResponder()
            }

            window.makeFirstResponder(to)
        }

        let queue = DispatchQueue.main
        if let delay {
            queue.asyncAfter(deadline: .now() + delay, execute: work)
        } else {
            queue.async(execute: work)
        }
    }
    #endif
}
