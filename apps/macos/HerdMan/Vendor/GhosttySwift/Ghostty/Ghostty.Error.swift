// HERDMAN-PATCH-BEGIN: explicit Foundation import (HerdMan builds with
// MemberImportVisibility; upstream gets Foundation transitively)
import Foundation
// HERDMAN-PATCH-END

extension Ghostty {
    /// Possible errors from internal Ghostty calls.
    enum Error: Swift.Error, CustomLocalizedStringResourceConvertible {
        case apiFailed

        var localizedStringResource: LocalizedStringResource {
            switch self {
            case .apiFailed: return "libghostty API call failed"
            }
        }
    }
}
