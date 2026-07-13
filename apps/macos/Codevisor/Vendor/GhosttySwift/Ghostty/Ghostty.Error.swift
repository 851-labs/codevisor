// CODEVISOR-PATCH-BEGIN: explicit Foundation import (Codevisor builds with
// MemberImportVisibility; upstream gets Foundation transitively)
import Foundation
// CODEVISOR-PATCH-END

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
