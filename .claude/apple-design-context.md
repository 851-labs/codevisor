# Apple Design Context

## Product

- **Name**: HerdMan
- **Description**: A native macOS app for running Claude Code, Codex, and ACP coding agents across local and remote machines.
- **Category**: Developer productivity
- **Stage**: Development

## Platforms

| Platform | Supported | Min OS   | Notes                                                   |
| -------- | --------- | -------- | ------------------------------------------------------- |
| iOS      | No        |          |                                                         |
| iPadOS   | No        |          |                                                         |
| macOS    | Yes       | macOS 26 | Primary native client; supports Apple Silicon and Intel |
| tvOS     | No        |          |                                                         |
| watchOS  | No        |          |                                                         |
| visionOS | No        |          |                                                         |

## Technology

- **UI Framework**: SwiftUI with AppKit integrations
- **Architecture**: Multi-window macOS app with a main `WindowGroup` and a separate Settings scene; local-first server with remote-machine support
- **Apple Technologies**: Quick Look, SwiftUI Settings scene

## Design System

- **Base**: Standard macOS controls and navigation with a custom theme system
- **Brand Colors**: Theme-defined semantic palette
- **Typography**: System fonts
- **Dark Mode**: Supported, including System/Light/Dark selection
- **Dynamic Type**: Uses semantic SwiftUI text styles; macOS accessibility sizing should be preserved

## Accessibility

- **Target Level**: Enhanced
- **Key Considerations**: VoiceOver labels and state, keyboard navigation, reduced motion, color-independent status indicators

## Users

- **Primary Persona**: Developers coordinating coding agents across projects and machines
- **Key Use Cases**: Start and resume agent sessions, switch harnesses, inspect tool activity, manage machines and integrations
- **Known Challenges**: Presenting cross-harness capabilities consistently while keeping credentials, connection health, and scope understandable
