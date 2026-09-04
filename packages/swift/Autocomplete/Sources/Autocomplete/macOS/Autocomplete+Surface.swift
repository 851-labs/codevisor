#if canImport(AppKit)
  import AppKit
  import SwiftUI

  extension Autocomplete {
    enum Presentation { case menu, inline }
    enum FocusTarget: Hashable {
      case item(NodeID)
      case secondary(NodeID, Int)
      var itemID: NodeID {
        switch self {
        case let .item(id), let .secondary(id, _): id
        }
      }
    }

    @MainActor
    final class PreparedCatalog {
      private var revision: UUID?
      private var locale: Locale?
      private var value: Catalog?
      private var queryKey: QueryKey?
      private var snapshot = Snapshot()
      private(set) var filterCount = 0
      private struct QueryKey: Equatable {
        let revision: UUID
        let query: String
        let filter: UUID
        let locale: Locale
      }

      func results(catalog: Catalog, query: String, filter: Filter, locale: Locale) -> Snapshot {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return catalog.unfiltered }
        let key = QueryKey(revision: catalog.revision, query: query, filter: filter.id, locale: locale)
        if queryKey != key {
          snapshot = catalog.results(query: query, filter: filter, locale: locale)
          queryKey = key
          filterCount += 1
        }
        return snapshot
      }

      func get(entries: [Entry], revision: UUID, locale: Locale) -> Catalog {
        if self.revision != revision || self.locale != locale || value == nil {
          value = Catalog(entries, locale: locale)
          self.revision = revision
          self.locale = locale
        }
        return value!
      }
    }

    struct Surface: View {
      let entries: [Entry]
      let mode: Presentation
      var query: Binding<String>?
      var focus: InputFocus?
      var onSubmit: (() -> Void)?
      var onDismiss: (() -> Void)?
      private let revision = UUID()
      @Environment(\.autocompleteConfiguration) private var configuration
      @Environment(\.autocompleteStyle) private var style
      @Environment(\.isEnabled) private var isEnabled
      @Environment(\.locale) private var locale
      @Environment(\.dynamicTypeSize) private var dynamicTypeSize
      @State private var localQuery = ""
      @State private var host = Host()
      @State private var prepared = PreparedCatalog()
      @State private var measurements = Measurements()
      @State private var coordinateSpace = UUID()
      @State private var isScrolling = false
      @State private var inputFocus = InputFocus()
      @FocusState private var focusedRow: FocusTarget?

      private var search: Binding<String> { query ?? $localQuery }
      private var metrics: Metrics {
        style.metrics.resolved(for: dynamicTypeSize)
      }

      var body: some View {
        let catalog = prepared.get(entries: entries, revision: revision, locale: locale)
        let full = catalog.unfiltered
        let results = prepared.results(
          catalog: catalog, query: search.wrappedValue, filter: configuration.filter, locale: locale)
        let snapshot = configuration.loading == .ready ? results : Snapshot()
        let metrics = metrics
        let heightSource = configuration.sizing == .stable ? full : snapshot
        let maximum = max(
          0, metrics.maximumHeight - metrics.inputTopInset - metrics.inputHeight - metrics.inputBottomInset)
        let listHeight = min(
          maximum, heightSource.listHeight(metrics: metrics, dividers: configuration.showsSectionDividers))
        VStack(spacing: 0) {
          InputField(
            text: search, prompt: configuration.prompt,
            accessibilityLabel: configuration.searchLabel ?? configuration.prompt,
            focusesOnAppear: mode == .menu, focusTick: (focus ?? inputFocus).requestTick,
            showsCheckmarks: catalog.showsCheckmarks, showsIcons: catalog.showsIcons,
            onCommand: handleInput, register: host.registerInput,
            onFocusChange: { configuration.searchFocused?.wrappedValue = $0 },
            onKeyEquivalent: host.handleKeyEquivalent, requestedFocus: configuration.requestedSearchFocus,
            onAdvanceFocus: advanceFocus
          )
          .frame(height: metrics.inputHeight)
          .padding(.horizontal, metrics.inputHorizontalInset)
          .padding(.top, metrics.inputTopInset)
          .padding(.bottom, metrics.inputBottomInset)
          resultsList(snapshot, catalog: catalog, height: listHeight, metrics: metrics)
        }
        .autocompleteStyle(
          Style(metrics: metrics, itemHighlight: style.itemHighlight, usesMiniScroller: style.usesMiniScroller)
        )
        .frame(width: measurements.popupWidth(catalog: catalog, metrics: metrics))
        .onChange(
          of: UpdateKey(
            revision: catalog.revision, targets: snapshot.eligibleIDs, query: search.wrappedValue, enabled: isEnabled,
            loading: configuration.loading, navigation: configuration.navigation, dismissal: configuration.dismissal),
          initial: true
        ) { _, _ in
          host.dismiss = dismiss
          host.dismissOnSelection =
            configuration.dismissal == .onSelection
            || (configuration.dismissal == .automatic && mode == .menu)
          host.update(
            snapshot: snapshot, query: search.wrappedValue, isEnabled: isEnabled,
            navigation: configuration.navigation ?? (mode == .menu ? .menu : .inline))
        }
        .onChange(of: focusedRow) { _, target in
          host.rowFocus = target
          if let target, host.snapshot.eligibleIDs.contains(target.itemID) { host.highlight.focus(target.itemID) }
        }
        .onKeyPress(phases: .down) { press in
          host.handleFocusedKey(press.key, modifiers: press.modifiers) ? .handled : .ignored
        }
        .onDisappear { host.stop() }
        .background { KeyMonitor(host: host).frame(width: 0, height: 0) }
      }

      private struct UpdateKey: Equatable {
        let revision: UUID
        let targets: [NodeID]
        let query: String
        let enabled: Bool
        let loading: LoadingState
        let navigation: Navigation?
        let dismissal: DismissBehavior
      }

      private func advanceFocus() -> Bool {
        guard isEnabled, let id = host.highlight.highlighted,
          let item = host.snapshot.byID[id], !item.definition.secondaryActions.isEmpty
        else { return false }
        focusedRow = .secondary(id, 0)
        return true
      }

      private func handleInput(_ command: KeyCommand) -> Bool {
        if host.handle(command) { return true }
        if command == .accept, isEnabled, let onSubmit { onSubmit(); return true }
        return false
      }

      private func dismiss() -> Bool {
        if let onDismiss { onDismiss(); return true }
        if !search.wrappedValue.isEmpty { search.wrappedValue = ""; return true }
        return false
      }

      private func resultsList(_ snapshot: Snapshot, catalog: Catalog, height: CGFloat, metrics: Metrics) -> some View {
        ScrollViewReader { proxy in
          ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
              if snapshot.items.isEmpty {
                status
                  .frame(maxWidth: .infinity)
                  .frame(height: max(0, height - 2 * metrics.listVerticalInset))
              }
              ForEach(snapshot.rows) { row in
                switch row.kind {
                case let .heading(title):
                  Text(title)
                    .font(metrics.groupLabelFont)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(height: metrics.groupLabelLineHeight)
                    .padding(
                      .leading,
                      metrics.textLeading(
                        showsCheckmarks: catalog.showsCheckmarks,
                        showsIcons: catalog.showsIcons) - metrics.listHorizontalInset
                    )
                    .padding(.top, metrics.groupLabelTopInset)
                    .padding(.bottom, metrics.groupLabelBottomInset)
                    .accessibilityAddTraits(.isHeader)
                case .separator:
                  if configuration.showsSectionDividers {
                    Rectangle().fill(.separator).frame(height: 1)
                      .padding(.horizontal, metrics.itemHorizontalInset)
                      .padding(.leading, catalog.showsCheckmarks ? metrics.checkColumnAdvance : 0)
                      .frame(height: metrics.dividerHeight)
                      .accessibilityHidden(true)
                  }
                case let .item(item):
                  ItemRow(
                    item: item, host: host, focus: $focusedRow,
                    showsChecks: catalog.showsCheckmarks, showsIcons: catalog.showsIcons,
                    isScrolling: isScrolling,
                    bottomEdge: BottomEdge(
                      isLast: item.id == snapshot.items.last?.id, height: height,
                      inset: metrics.listVerticalInset, coordinateSpace: coordinateSpace)
                  )
                  .id(item.id)
                }
              }
            }
            .padding(.horizontal, metrics.listHorizontalInset)
            .padding(.vertical, metrics.listVerticalInset)
            .background { ScrollConfigurator(usesMiniScroller: style.usesMiniScroller, onResolve: host.linkResults) }
          }
          .scrollBounceBehavior(.basedOnSize)
          .onScrollPhaseChange { _, phase in isScrolling = phase != .idle }
          .onChange(of: host.highlight.highlighted) { _, target in
            guard let target, host.highlight.source == .keyboard else { return }
            if let focusedRow, focusedRow.itemID != target { self.focusedRow = .item(target) }
            proxy.scrollTo(target)
            host.announce()
          }
          .accessibilityElement(children: .contain)
          .accessibilityLabel(configuration.searchLabel ?? configuration.prompt)
          .accessibilityValue(Strings.resultCount(snapshot.items.count))
        }
        .frame(height: height)
        .coordinateSpace(name: coordinateSpace)
      }

      @ViewBuilder private var status: some View {
        switch configuration.loading {
        case .ready:
          Text(search.wrappedValue.isEmpty ? configuration.noItemsMessage : configuration.emptyMessage)
            .foregroundStyle(.secondary)
            .font(metrics.menuFont)
        case let .loading(message):
          HStack {
            ProgressView().controlSize(.small); Text(message)
          }.accessibilityElement(children: .combine)
        case let .failure(message):
          Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
        }
      }

    }
  }
#endif
