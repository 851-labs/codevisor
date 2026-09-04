#if canImport(AppKit)
  import SwiftUI

  public extension Autocomplete {
    /// A searchable menu including its trigger, presentation, and dismissal.
    /// Compose commands and independently selection-bound Picker groups.
    struct Menu<Label: View>: View {
      let entries: [Entry]
      let label: Label
      let presentation: Binding<Bool>?
      @State private var isPresented = false
      @Environment(\.isEnabled) private var isEnabled

      public init(
        isPresented: Binding<Bool>? = nil,
        @ContentBuilder content: () -> [Entry], @ViewBuilder label: () -> Label
      ) {
        entries = content()
        self.label = label()
        presentation = isPresented
      }

      private var presented: Binding<Bool> { presentation ?? $isPresented }
      public var body: some View {
        Button {
          presented.wrappedValue.toggle()
        } label: {
          label
        }
        .popover(isPresented: presented, attachmentAnchor: .rect(.bounds), arrowEdge: .bottom) {
          Surface(entries: entries, mode: .menu, onDismiss: { presented.wrappedValue = false })
            .disabled(!isEnabled)
        }
        .onChange(of: isEnabled) { _, enabled in
          if !enabled { presented.wrappedValue = false }
        }
      }
    }

    /// An inline search field and results. The host can bind its query, hand
    /// over focus explicitly, and receive an otherwise unhandled Return.
    struct Suggestions: View {
      let entries: [Entry]
      let query: Binding<String>?
      let focus: InputFocus?
      let onSubmit: (() -> Void)?
      let onCancel: (() -> Void)?

      public init(
        query: Binding<String>? = nil, focus: InputFocus? = nil,
        onSubmit: (() -> Void)? = nil, onCancel: (() -> Void)? = nil,
        @ContentBuilder content: () -> [Entry]
      ) {
        self.query = query
        self.focus = focus
        self.onSubmit = onSubmit
        self.onCancel = onCancel
        entries = content()
      }

      public var body: some View {
        Surface(
          entries: entries, mode: .inline, query: query, focus: focus,
          onSubmit: onSubmit, onDismiss: onCancel)
      }
    }

    enum Sizing: Sendable { case stable, fitResults }
    enum DismissBehavior: Sendable { case automatic, onSelection, never }
    enum LoadingState: Equatable, Sendable {
      case ready
      case loading(String)
      case failure(String)
    }
  }

  extension Autocomplete {
    struct Configuration {
      var prompt = Strings.text("Search")
      var searchLabel: String?
      var emptyMessage = Strings.text("No matches")
      var noItemsMessage = Strings.text("No items available")
      var filter: Filter = .contains
      var sizing: Sizing = .stable
      var showsSectionDividers = true
      var navigation: Navigation?
      var dismissal: DismissBehavior = .automatic
      var loading: LoadingState = .ready
      var searchFocused: Binding<Bool>?
      var requestedSearchFocus: Bool?
    }
  }

  extension EnvironmentValues {
    @Entry var autocompleteConfiguration = Autocomplete.Configuration()
  }

  public extension View {
    func autocompleteSearchPrompt(_ prompt: String) -> some View {
      transformEnvironment(\.autocompleteConfiguration) { $0.prompt = prompt }
    }
    func autocompleteSearchLabel(_ label: String) -> some View {
      transformEnvironment(\.autocompleteConfiguration) { $0.searchLabel = label }
    }
    func autocompleteEmptyMessage(_ message: String, noItems: String? = nil) -> some View {
      transformEnvironment(\.autocompleteConfiguration) {
        $0.emptyMessage = message
        if let noItems { $0.noItemsMessage = noItems }
      }
    }
    func autocompleteFilter(_ filter: Autocomplete.Filter) -> some View {
      transformEnvironment(\.autocompleteConfiguration) { $0.filter = filter }
    }
    func autocompleteSizing(_ sizing: Autocomplete.Sizing) -> some View {
      transformEnvironment(\.autocompleteConfiguration) { $0.sizing = sizing }
    }
    func autocompleteSectionDividers(_ visibility: Visibility) -> some View {
      transformEnvironment(\.autocompleteConfiguration) { $0.showsSectionDividers = visibility != .hidden }
    }
    func autocompleteNavigation(_ navigation: Autocomplete.Navigation) -> some View {
      transformEnvironment(\.autocompleteConfiguration) { $0.navigation = navigation }
    }
    func autocompleteDismissBehavior(_ behavior: Autocomplete.DismissBehavior) -> some View {
      transformEnvironment(\.autocompleteConfiguration) { $0.dismissal = behavior }
    }
    func autocompleteLoadingState(_ state: Autocomplete.LoadingState) -> some View {
      transformEnvironment(\.autocompleteConfiguration) { $0.loading = state }
    }
    func autocompleteSearchFocused(_ focused: Binding<Bool>) -> some View {
      let requested = focused.wrappedValue
      return transformEnvironment(\.autocompleteConfiguration) {
        $0.searchFocused = focused
        $0.requestedSearchFocus = requested
      }
    }
  }
#endif
