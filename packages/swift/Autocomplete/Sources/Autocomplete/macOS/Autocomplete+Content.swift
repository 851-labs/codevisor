#if canImport(AppKit)
  import SwiftUI

  /// Semantic content accepted by an autocomplete menu. Standard ForEach and
  /// builder conditionals expand this content before any rows are rendered.
  @MainActor
  public protocol AutocompleteMenuContent {
    var autocompleteEntries: [Autocomplete.Entry] { get }
  }

  @MainActor
  public protocol AutocompleteChoiceContent {
    associatedtype Value: Hashable
    var autocompleteChoices: [Autocomplete.Choice<Value>] { get }
  }

  extension ForEach: AutocompleteMenuContent where Content: AutocompleteMenuContent {
    public var autocompleteEntries: [Autocomplete.Entry] { data.flatMap { content($0).autocompleteEntries } }
  }

  extension ForEach: AutocompleteChoiceContent where Content: AutocompleteChoiceContent {
    public typealias Value = Content.Value
    public var autocompleteChoices: [Autocomplete.Choice<Value>] { data.flatMap { content($0).autocompleteChoices } }
  }

  public extension Autocomplete {
    @resultBuilder
    @MainActor
    enum ContentBuilder {
      public static func buildExpression<C: AutocompleteMenuContent>(_ content: C) -> [Entry] {
        content.autocompleteEntries
      }
      public static func buildExpression(_ entries: [Entry]) -> [Entry] { entries }
      public static func buildBlock(_ parts: [Entry]...) -> [Entry] { parts.flatMap { $0 } }
      public static func buildOptional(_ part: [Entry]?) -> [Entry] { part ?? [] }
      public static func buildEither(first: [Entry]) -> [Entry] { first }
      public static func buildEither(second: [Entry]) -> [Entry] { second }
      public static func buildArray(_ parts: [[Entry]]) -> [Entry] { parts.flatMap { $0 } }
      public static func buildLimitedAvailability(_ part: [Entry]) -> [Entry] { part }
    }

    @resultBuilder
    @MainActor
    enum ChoiceBuilder<Value: Hashable> {
      public static func buildExpression<C: AutocompleteChoiceContent>(_ content: C) -> [Choice<Value>]
      where C.Value == Value { content.autocompleteChoices }
      public static func buildBlock(_ parts: [Choice<Value>]...) -> [Choice<Value>] { parts.flatMap { $0 } }
      public static func buildOptional(_ part: [Choice<Value>]?) -> [Choice<Value>] { part ?? [] }
      public static func buildEither(first: [Choice<Value>]) -> [Choice<Value>] { first }
      public static func buildEither(second: [Choice<Value>]) -> [Choice<Value>] { second }
      public static func buildArray(_ parts: [[Choice<Value>]]) -> [Choice<Value>] { parts.flatMap { $0 } }
      public static func buildLimitedAvailability(_ part: [Choice<Value>]) -> [Choice<Value>] { part }
    }

    /// An opaque semantic entry. Use Choice, Action, Picker, and Section to
    /// build entries; view realization is never the source of keyboard order.
    struct Entry {
      indirect enum Kind {
        case item(ItemDefinition)
        case section(AnyHashable, String?, [Entry])
      }
      let kind: Kind

      func disabling(_ disabled: Bool) -> Entry {
        guard disabled else { return self }
        switch kind {
        case var .item(item):
          item.isDisabled = true
          return Entry(kind: .item(item))
        case let .section(id, title, children):
          return Entry(kind: .section(id, title, children.map { $0.disabling(true) }))
        }
      }
    }

    /// A secondary action is reachable from the row's accessibility actions,
    /// context menu, and optional local keyboard shortcut.
    struct SecondaryAction {
      public let title: String
      public let systemImage: String
      public var shortcut: KeyboardShortcut?
      let perform: @MainActor () -> Void

      public init(
        _ title: String, systemImage: String, shortcut: KeyboardShortcut? = nil,
        action: @escaping @MainActor () -> Void
      ) {
        self.title = title
        self.systemImage = systemImage
        self.shortcut = shortcut
        perform = action
      }
    }

    /// A value in a selection-bound Picker. The title supplies search,
    /// measurement, and accessibility text even when the label is custom.
    struct Choice<Value: Hashable>: View, AutocompleteChoiceContent {
      let value: Value
      var definition: ItemDefinition
      var isFavoritable = true

      public init(_ title: String, value: Value, systemImage: String? = nil) {
        self.value = value
        definition = ItemDefinition(id: AnyHashable(value), title: title)
        definition.icon = systemImage.map { AnyView(Image(systemName: $0)) }
      }

      public init(
        _ title: String, value: Value, @ViewBuilder icon: () -> some View,
        @ViewBuilder label: () -> some View
      ) {
        self.value = value
        definition = ItemDefinition(id: AnyHashable(value), title: title)
        definition.icon = AnyView(icon())
        definition.label = AnyView(label())
      }

      public init(_ title: String, value: Value, @ViewBuilder label: () -> some View) {
        self.init(title, value: value)
        definition.label = AnyView(label())
      }

      public var body: some View { EmptyView() }
      public var autocompleteChoices: [Self] { [self] }

      public func disabled(_ disabled: Bool = true) -> Self {
        var copy = self; copy.definition.isDisabled = disabled; return copy
      }
      public func searchTerms(_ terms: [String]) -> Self {
        var copy = self; copy.definition.keywords = terms; return copy
      }
      public func help(_ text: String) -> Self {
        var copy = self; copy.definition.help = text; return copy
      }
      public func favoritable(_ value: Bool) -> Self {
        var copy = self; copy.isFavoritable = value; return copy
      }
      public func secondaryActions(_ actions: [SecondaryAction]) -> Self {
        var copy = self; copy.definition.secondaryActions = actions; return copy
      }
      public func keyboardShortcut(_ shortcut: KeyboardShortcut?) -> Self {
        var copy = self; copy.definition.shortcut = shortcut; return copy
      }
      public func keyboardShortcut(_ key: KeyEquivalent, modifiers: EventModifiers = .command) -> Self {
        keyboardShortcut(KeyboardShortcut(key, modifiers: modifiers))
      }
    }

    /// A command, separate from a selectable value. Shortcuts are active only
    /// while this autocomplete owns keyboard focus.
    struct Action: View, AutocompleteMenuContent {
      var definition: ItemDefinition

      public init(
        _ title: String, id: AnyHashable? = nil, systemImage: String? = nil,
        role: ButtonRole? = nil, action: @escaping @MainActor () -> Void
      ) {
        definition = ItemDefinition(id: id ?? AnyHashable(title), title: title)
        definition.icon = systemImage.map { AnyView(Image(systemName: $0)) }
        definition.role = role
        definition.perform = action
      }

      public init(
        _ title: String, id: AnyHashable, action: @escaping @MainActor () -> Void,
        @ViewBuilder icon: () -> some View, @ViewBuilder label: () -> some View
      ) {
        self.init(title, id: id, action: action)
        definition.icon = AnyView(icon())
        definition.label = AnyView(label())
      }

      public var body: some View { EmptyView() }
      public var autocompleteEntries: [Entry] { [Entry(kind: .item(definition))] }

      public func disabled(_ disabled: Bool = true) -> Self {
        var copy = self; copy.definition.isDisabled = disabled; return copy
      }
      public func searchTerms(_ terms: [String]) -> Self {
        var copy = self; copy.definition.keywords = terms; return copy
      }
      public func help(_ text: String) -> Self {
        var copy = self; copy.definition.help = text; return copy
      }
      public func keyboardShortcut(_ shortcut: KeyboardShortcut?) -> Self {
        var copy = self; copy.definition.shortcut = shortcut; return copy
      }
      public func keyboardShortcut(_ key: KeyEquivalent, modifiers: EventModifiers = .command) -> Self {
        keyboardShortcut(KeyboardShortcut(key, modifiers: modifiers))
      }
      public func secondaryActions(_ actions: [SecondaryAction]) -> Self {
        var copy = self; copy.definition.secondaryActions = actions; return copy
      }
    }

    /// A titled or untitled section with a stable, typed identity.
    struct Section: View, AutocompleteMenuContent {
      let id: AnyHashable
      let title: String?
      let entries: [Entry]
      var isDisabled = false

      public init(_ title: String, id: AnyHashable? = nil, @ContentBuilder content: () -> [Entry]) {
        self.id = id ?? AnyHashable(title)
        self.title = title
        entries = content()
      }

      public init(id: AnyHashable, @ContentBuilder content: () -> [Entry]) {
        self.id = id
        title = nil
        entries = content()
      }

      public var body: some View { EmptyView() }
      public var autocompleteEntries: [Entry] { [Entry(kind: .section(id, title, entries)).disabling(isDisabled)] }
      public func disabled(_ disabled: Bool = true) -> Self {
        var copy = self; copy.isDisabled = disabled; return copy
      }
    }

    /// Use inside Menu/Suggestions for an inline choice group, or on its own
    /// for a menu whose trigger displays the current value.
    struct Picker<Value: Hashable>: View, AutocompleteMenuContent {
      let title: String
      let id: AnyHashable
      let selection: Binding<Value>
      let choices: [Choice<Value>]
      var favoriteIDs: Binding<[Value]>?
      var showsTitle = true
      var isDisabled = false

      public init(
        _ title: String, id: AnyHashable? = nil, selection: Binding<Value>,
        @ChoiceBuilder<Value> content: () -> [Choice<Value>]
      ) {
        self.title = title
        self.id = id ?? AnyHashable(title)
        self.selection = selection
        choices = content()
      }

      public init<Data: RandomAccessCollection>(
        _ title: String, id: AnyHashable? = nil, selection: Binding<Value>, options: Data,
        choice: (Data.Element) -> Choice<Value>
      ) {
        self.title = title
        self.id = id ?? AnyHashable(title)
        self.selection = selection
        choices = options.map(choice)
      }

      public func favorites(_ ids: Binding<[Value]>) -> Self {
        var copy = self; copy.favoriteIDs = ids; return copy
      }
      public func labelsHidden() -> Self {
        var copy = self; copy.showsTitle = false; return copy
      }
      public func disabled(_ disabled: Bool = true) -> Self {
        var copy = self; copy.isDisabled = disabled; return copy
      }

      public var autocompleteEntries: [Entry] {
        var favoriteOrder: [Value: Int] = [:]
        for (index, value) in (favoriteIDs?.wrappedValue ?? []).enumerated() where favoriteOrder[value] == nil {
          favoriteOrder[value] = index
        }
        let entries = choices.map { choice -> Entry in
          var item = choice.definition
          item.isChoice = true
          item.isSelected = selection.wrappedValue == choice.value
          item.isDisabled = item.isDisabled || isDisabled
          item.keywords.append(title)
          item.perform = { selection.wrappedValue = choice.value }
          if choice.isFavoritable, let favoriteIDs {
            item.favoriteOrder = favoriteOrder[choice.value]
            let favoriteAction = FavoriteAction(isFavorite: item.favoriteOrder != nil)
            item.secondaryActions.insert(
              SecondaryAction(
                favoriteAction.label, systemImage: favoriteAction.symbolName,
                shortcut: KeyboardShortcut("f", modifiers: [.command, .shift])
              ) {
                var values = favoriteIDs.wrappedValue
                if values.contains(choice.value) {
                  values.removeAll { $0 == choice.value }
                } else {
                  values.append(choice.value)
                }
                favoriteIDs.wrappedValue = values
              }, at: 0)
          }
          return Entry(kind: .item(item))
        }
        return [Entry(kind: .section(id, showsTitle ? title : nil, entries))]
      }

      public var body: some View {
        Menu {
          autocompleteEntries
        } label: {
          Text(choices.first { $0.value == selection.wrappedValue }?.definition.title ?? title)
        }
        .disabled(isDisabled)
        .accessibilityLabel(title)
      }
    }
  }

  extension Autocomplete {
    @MainActor
    struct ItemDefinition {
      let id: AnyHashable
      let title: String
      var keywords: [String] = []
      var label: AnyView?
      var icon: AnyView?
      var role: ButtonRole?
      var shortcut: KeyboardShortcut?
      var isChoice = false
      var isSelected = false
      var isDisabled = false
      var favoriteOrder: Int?
      var help: String?
      var secondaryActions: [SecondaryAction] = []
      var perform: @MainActor () -> Void = {}
    }
  }
#endif
