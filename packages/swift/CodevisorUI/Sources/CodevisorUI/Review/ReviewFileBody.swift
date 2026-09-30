import CodevisorCore
import SwiftUI

/// Header rows take the platform's comfortable tap height; expand rows stay
/// short, like GitHub's, so folds don't dominate the diff.
enum ReviewMetrics {
  #if os(iOS)
    static let minimumTapHeight: CGFloat = 44
    static let foldRowHeight: CGFloat = 30
  #else
    static let minimumTapHeight: CGFloat = 32
    static let foldRowHeight: CGFloat = 22
  #endif
}

/// A changed file's header: disclosure, path, change kind, and line totals.
/// Pinned while its diff scrolls past, so the reader always knows the file.
struct ReviewFileHeader: View {
  let diff: ReviewFileDiff
  let isCollapsed: Bool
  let isViewed: Bool
  let toggle: () -> Void
  let toggleViewed: () -> Void
  /// Counts the reader's own taps on the viewed circle, so the haptic
  /// answers a tap and never a mark that synced in or lapsed on its own.
  @State private var viewedTaps = 0

  var body: some View {
    HStack(spacing: 0) {
      disclosure
      viewedButton
    }
  }

  private var disclosure: some View {
    Button(action: toggle) {
      HStack(spacing: 8) {
        Image(systemName: "chevron.right")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
          .rotationEffect(.degrees(isCollapsed ? 0 : 90))
          .frame(width: 12)
        FileIcon(path: diff.file.path, size: 16)
        pathLabel
        Spacer(minLength: 8)
        if diff.file.omitted == nil {
          DiffCounter(totals: diff.totals)
        }
      }
      .padding(.leading, 12)
      .padding(.trailing, 4)
      .padding(.vertical, 8)
      .frame(minHeight: ReviewMetrics.minimumTapHeight)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(accessibilityLabel)
    .accessibilityValue(isCollapsed ? "Collapsed" : "Expanded")
    .accessibilityHint(isCollapsed ? "Shows the file's changes" : "Hides the file's changes")
    .help(diff.file.oldPath.map { "\($0) → \(diff.file.path)" } ?? diff.file.path)
  }

  /// GitHub's "Viewed" circle: marking folds the file away, and the mark
  /// lapses by itself once the file changes again.
  private var viewedButton: some View {
    Button {
      viewedTaps += 1
      toggleViewed()
    } label: {
      Image(systemName: isViewed ? "checkmark.circle.fill" : "circle")
        .font(.body)
        .foregroundStyle(isViewed ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
        .contentTransition(.symbolEffect(.replace))
        .frame(width: ReviewMetrics.minimumTapHeight, height: ReviewMetrics.minimumTapHeight)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .padding(.trailing, 4)
    #if os(iOS)
      .sensoryFeedback(.impact(weight: .light), trigger: viewedTaps)
    #endif
    .accessibilityLabel("Viewed")
    .accessibilityValue(isViewed ? "Checked" : "Unchecked")
    .accessibilityAddTraits(isViewed ? .isSelected : [])
    .help(isViewed ? "Mark as Not Viewed" : "Mark as Viewed")
  }

  /// Directory dimmed, file name emphasized; long paths truncate in the
  /// middle so both ends stay readable.
  private var pathLabel: some View {
    let path = diff.file.path
    let name = (path as NSString).lastPathComponent
    let directory = String(path.dropLast(name.count))
    return Text("\(Text(directory).foregroundStyle(.secondary))\(Text(name).fontWeight(.semibold))")
      .font(.callout)
      .lineLimit(1)
      .truncationMode(.middle)
  }

  /// Spoken only: the header stays visually quiet.
  private var statusDescription: String? {
    switch diff.file.status {
    case .added: "Added"
    case .deleted: "Deleted"
    case .renamed: "Renamed"
    case .modified: nil
    }
  }

  private var accessibilityLabel: String {
    var parts = [diff.file.path]
    if let statusDescription { parts.append(statusDescription) }
    if let oldPath = diff.file.oldPath { parts.append("from \(oldPath)") }
    if diff.file.omitted == nil {
      parts.append("\(diff.totals.added) added, \(diff.totals.removed) removed")
    }
    return parts.joined(separator: ", ")
  }
}

/// A file's diff with unchanged runs folded. Hunks render through the same
/// native TextKit surface as transcript edit cards, grown to full height so
/// the pane's scroll view owns vertical scrolling.
struct ReviewFileBody: View {
  let diff: ReviewFileDiff
  @State private var expansions: [Int: ReviewGapExpansion] = [:]
  /// The file's hunks scroll sideways as one.
  @State private var scrollSync = DiffScrollSync()
  /// Syntax colors, tagged with the exact content (`highlightKey`) they
  /// were computed for. Highlights are keyed by row position and carry
  /// their own text, so a set computed for older content must never paint
  /// newer rows: it would show the old lines.
  @State private var highlighted: (key: String, rows: [Int: AttributedString])?
  @Environment(\.theme) private var theme
  @Environment(\.codeHighlightTheme) private var highlightTheme

  var body: some View {
    Group {
      if let note {
        Text(note)
          .font(.callout)
          .foregroundStyle(.secondary)
          .padding(.horizontal, 12)
          .padding(.vertical, 10)
          .frame(maxWidth: .infinity, alignment: .leading)
      } else {
        VStack(spacing: 0) {
          ForEach(ReviewDiffSegment.segments(for: diff.rows, expansions: expansions)) { segment in
            switch segment {
            case let .rows(rows): hunk(rows, id: segment.id)
            case let .gap(gap): self.gap(gap)
            }
          }
        }
      }
    }
    .task(id: highlightKey) {
      let key = highlightKey
      let rows = await DiffHighlighting.highlights(
        rows: diff.rows, old: diff.file.oldText, new: diff.file.newText ?? "",
        path: diff.file.path, theme: highlightTheme)
      guard !Task.isCancelled else { return }
      highlighted = (key, rows)
    }
  }

  private var note: String? {
    switch diff.file.omitted {
    case .binary: return "Binary file not shown."
    case .tooLarge: return "This file is too large to show."
    case nil: break
    }
    guard diff.rows.isEmpty || (diff.totals.added == 0 && diff.totals.removed == 0) else { return nil }
    switch diff.file.status {
    case .renamed: return "Renamed without content changes."
    case .added: return "Empty file."
    case .deleted: return "Empty file deleted."
    case .modified: return "No content changes."
    }
  }

  /// Highlights for the content on screen, or none until they catch up.
  private var currentHighlights: [Int: AttributedString] {
    highlighted?.key == highlightKey ? highlighted?.rows ?? [:] : [:]
  }

  private var highlightKey: String {
    "\(highlightTheme?.key ?? "")|\(diff.file.path)|\(diff.revision)"
  }

  /// Every hunk reserves the gutter for the file's largest line number so
  /// columns line up across folds.
  private var lineNumberDigits: Int {
    max(2, String(diff.maxLineNumber).count)
  }

  @ViewBuilder
  private func hunk(_ rows: [LineDiff.Row], id: Int) -> some View {
    let highlights = currentHighlights
    // Redraw when the content or the highlight set that applies changes.
    let revision = "\(diff.revision)|\(id)|\(rows.count)|\(highlights.isEmpty ? "plain" : "colored")"
    #if canImport(AppKit)
      NativeDiffView(
        rows: rows, highlights: highlights, theme: theme, revision: revision,
        maximumHeight: nil, lineNumberDigits: lineNumberDigits, scrollSync: scrollSync
      )
      .frame(maxWidth: .infinity, alignment: .leading)
    #elseif canImport(UIKit)
      IOSNativeDiffView(
        rows: rows, highlights: highlights, theme: theme, revision: revision,
        maximumHeight: nil, lineNumberDigits: lineNumberDigits, scrollSync: scrollSync
      )
      .frame(maxWidth: .infinity, alignment: .leading)
    #endif
  }

  /// A fold offers GitHub's two ways in: "Show next lines" continues below
  /// the hunk above, and the next hunk's `@@` header expands upward. Each
  /// opens a step; a fold no bigger than a step opens whole.
  @ViewBuilder
  private func gap(_ gap: ReviewDiffSegment.Gap) -> some View {
    let step = ReviewDiffSegment.expandStep
    if gap.rows.count <= step {
      expandRow(
        systemImage: "arrow.up.and.down",
        title: gap.nextHunkHeader ?? "Show \(gap.rows.count) lines",
        isHunkHeader: gap.nextHunkHeader != nil,
        accessibilityLabel: gap.rows.count == 1 ? "Show 1 hidden line" : "Show \(gap.rows.count) hidden lines"
      ) {
        expansions[gap.id, default: ReviewGapExpansion()].top += gap.rows.count
      }
    } else {
      if !gap.isLeading {
        expandRow(
          systemImage: "arrow.down.to.line.compact", title: "Show next lines", isHunkHeader: false,
          accessibilityLabel: "Show next \(step) lines"
        ) {
          expansions[gap.id, default: ReviewGapExpansion()].top += step
        }
      }
      if !gap.isTrailing, let header = gap.nextHunkHeader {
        expandRow(
          systemImage: "arrow.up.to.line.compact", title: header, isHunkHeader: true,
          accessibilityLabel: "Show \(step) previous lines"
        ) {
          expansions[gap.id, default: ReviewGapExpansion()].bottom += step
        }
      }
    }
  }

  private func expandRow(
    systemImage: String, title: String, isHunkHeader: Bool, accessibilityLabel: String,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      HStack(spacing: 10) {
        Image(systemName: systemImage)
          .font(.caption.weight(.semibold))
          .frame(width: 16)
        Text(title)
          .font(isHunkHeader ? .caption.monospaced() : .caption)
          .foregroundStyle(isHunkHeader ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
          .lineLimit(1)
          .truncationMode(.tail)
        Spacer(minLength: 0)
      }
      .foregroundStyle(.tint)
      .padding(.horizontal, 12)
      .frame(maxWidth: .infinity, minHeight: ReviewMetrics.foldRowHeight, alignment: .leading)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .background(Color.accentColor.opacity(0.08))
    .accessibilityLabel(accessibilityLabel)
  }
}
