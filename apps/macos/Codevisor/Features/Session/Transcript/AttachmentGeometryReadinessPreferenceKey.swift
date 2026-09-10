import SwiftUI
import StreamMarkdown

/// Aggregates unresolved, layout-affecting attachment geometry through a
/// hosted transcript row. The native presentation gate consumes this before
/// accepting the row's measured height as final.
typealias AttachmentGeometryReadinessPreferenceKey = ContentLayoutReadinessPreferenceKey
