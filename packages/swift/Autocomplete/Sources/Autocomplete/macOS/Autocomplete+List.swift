#if canImport(AppKit)
  import AppKit
  import SwiftUI

  public extension Autocomplete {
    /// The scrolling body of a popup. Put `Group`s, `Item`s, conditionals,
    /// and `ForEach` inside; the list scrolls the keyboard target into view
    /// and reports leaving hover to the highlight.
    ///
    /// Pass `height` to pin the list (e.g. measured from the unfiltered
    /// contents with `Metrics.listHeight`) so filtering never resizes the
    /// popover. Without it the list takes its content height, capped at the
    /// style's maximum.
    struct List<Content: View>: View {
      let height: CGFloat?
      let content: Content

      @Environment(\.autocompleteStyle) private var style
      @Environment(Host.self) private var host
      @State private var isScrolling = false

      public init(height: CGFloat? = nil, @ViewBuilder content: () -> Content) {
        self.height = height
        self.content = content()
      }

      public var body: some View {
        let metrics = style.metrics
        ScrollViewReader { proxy in
          ScrollView {
            // Spacing belongs between groups, not between bare items, so
            // lay children out flush and pad each group that follows
            // something else.
            VStack(alignment: .leading, spacing: 0) {
              SwiftUI.Group(subviews: content) { subviews in
                ForEach(subviews.indices, id: \.self) { index in
                  subviews[index]
                    .padding(
                      .top, index > 0 && subviews[index].containerValues.autocompleteIsGroup ? metrics.groupSpacing : 0)
                }
              }
            }
            .padding(.horizontal, metrics.listHorizontalInset)
            .padding(.vertical, metrics.listVerticalInset)
            .environment(\.autocompleteIsScrolling, isScrolling)
            .environment(\.autocompleteItemBottomInset, metrics.listVerticalInset)
            .background {
              if style.usesMiniScroller {
                MiniScrollerConfigurator()
              }
            }
          }
          .scrollBounceBehavior(bounceBehavior)
          .onScrollPhaseChange { _, phase in
            isScrolling = phase != .idle
          }
          .onDisappear {
            isScrolling = false
          }
          .onChange(of: host.scrollTick) {
            guard let target = host.scrollTarget else { return }
            proxy.scrollTo(target, anchor: .center)
          }
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .frame(maxHeight: height == nil ? metrics.maximumHeight : nil)
      }

      private var bounceBehavior: ScrollBounceBehavior {
        guard let height else { return .basedOnSize }
        let itemCount = host.targets.filter { $0.kind == .item }.count
        let labelCount = host.targets.filter { $0.kind == .groupLabel }.count
        let contentHeight = style.metrics.listContentHeight(itemCount: itemCount, groupLabelCount: labelCount)
        return contentHeight > height ? .always : .basedOnSize
      }
    }

    /// A titled run of items.
    struct Group<Content: View>: View {
      let title: String
      let content: Content

      public init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
      }

      public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
          GroupLabel(title)
          content
        }
        .containerValue(\.autocompleteIsGroup, true)
      }
    }

    /// The secondary-styled heading above a group of items. Registers with
    /// `Root` so list height accounts for it.
    struct GroupLabel: View {
      let title: String

      @Environment(\.autocompleteStyle) private var style
      @Environment(\.autocompleteShowsCheckmarks) private var showsCheckmarks
      @Environment(\.autocompleteShowsIcons) private var showsIcons

      public init(_ title: String) {
        self.title = title
      }

      public var body: some View {
        let metrics = style.metrics
        Text(title)
          .font(metrics.groupLabelFont)
          .foregroundStyle(.secondary)
          // On the title keyline, past the check and icon columns.
          .padding(
            .leading,
            metrics.textLeading(showsCheckmarks: showsCheckmarks, showsIcons: showsIcons) - metrics.listHorizontalInset
          )
          .padding(.trailing, metrics.groupLabelInset)
          .padding(.top, metrics.groupLabelTopInset)
          .padding(.bottom, metrics.groupLabelBottomInset)
          .preference(
            key: ContentsKey.self,
            value: Contents(targets: [Target(id: AnyHashable("group-label:\(title)"), kind: .groupLabel)])
          )
      }
    }

    /// A hairline between runs of items. With a check column it starts at
    /// the title keyline rather than the popup edge, the way menu separators
    /// do; it is never a keyboard target.
    struct Divider: View {
      @Environment(\.autocompleteStyle) private var style
      @Environment(\.autocompleteShowsCheckmarks) private var showsCheckmarks

      public init() {}

      public var body: some View {
        let metrics = style.metrics
        Rectangle()
          .fill(.separator)
          .frame(height: 1)
          .padding(.leading, metrics.itemHorizontalInset + (showsCheckmarks ? metrics.checkColumnAdvance : 0))
          .padding(.trailing, metrics.itemHorizontalInset)
          .frame(height: metrics.dividerHeight)
          .accessibilityHidden(true)
      }
    }

    /// What the list shows when the filter matches nothing. Fills the list's
    /// visible height so the message sits centered in a pinned list.
    struct Empty: View {
      let text: String

      @Environment(\.autocompleteStyle) private var style

      public init(_ text: String) {
        self.text = text
      }

      public var body: some View {
        let metrics = style.metrics
        Text(text)
          .font(.system(size: 13))
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity)
          .containerRelativeFrame(.vertical) { length, _ in
            max(length - 2 * metrics.listVerticalInset, metrics.emptyListHeight - 2 * metrics.listVerticalInset)
          }
      }
    }
  }

  extension ContainerValues {
    /// Marks a `Group` so `List` can put inter-group spacing before it.
    @Entry var autocompleteIsGroup = false
  }

  extension EnvironmentValues {
    /// Only rows inside the moving list suppress hover; pinned footer items
    /// keep their normal pointer behavior.
    @Entry var autocompleteIsScrolling = false
    /// The expected gap between a final item and the popup's bottom edge.
    @Entry var autocompleteItemBottomInset: CGFloat = 0
  }

  extension Autocomplete {
    /// SwiftUI exposes scroll-indicator visibility but not AppKit's native
    /// control sizes. This zero-size probe keeps the list on the system
    /// scroller style while using the compact width of a mini vertical
    /// scroller.
    struct MiniScrollerConfigurator: NSViewRepresentable {
      func makeNSView(context: Context) -> ConfiguratorView {
        ConfiguratorView()
      }

      func updateNSView(_ view: ConfiguratorView, context: Context) {
        view.apply()
      }

      final class ConfiguratorView: NSView {
        override func viewDidMoveToWindow() {
          super.viewDidMoveToWindow()
          apply()
        }

        func apply() {
          DispatchQueue.main.async { [weak self] in
            guard
              let scrollView = self?.enclosingScrollView,
              let scroller = scrollView.verticalScroller,
              scroller.controlSize != .mini
            else { return }
            scroller.controlSize = .mini
            scrollView.tile()
          }
        }
      }
    }
  }
#endif
