# Solution: Buffer Navigation Updates During Sync

## Problem Statement

iOS navigation was experiencing jarring layout shifts during event replay/sync. As the app caught up with server events, each navigation delta was applied immediately, causing the list to reorder item-by-item in a visually disruptive way.

## Root Cause

In the original implementation:
1. During catch-up, `handleSyncEvent` in `MachineController+NavigationSync.swift` applied each `navigation.changed` event immediately
2. Each delta triggered `projectList.commitSnapshot()`, causing the UI to update incrementally
3. This resulted in visible reordering as items were added/moved one by one during the initial event replay

## Solution Design

### 1. Buffering Mechanism

**`NavigationSyncState` Enhancement** (`NavigationSyncState.swift`)
```swift
// Before:
case catchingUp

// After:
case catchingUp(bufferedEvents: Int = 0)
```

Added an associated value to track the number of buffered events, providing visibility into sync progress.

**`MachineConnection` Buffer Management** (`MachineConnection.swift`)
- Added `bufferedNavigationDeltas: [ServerNavigationDelta]` array to collect deltas during catch-up
- Added helper methods:
  - `isBufferingNavigation()`: Check if currently in buffering mode
  - `bufferNavigationDelta(_:)`: Add a delta to the buffer and update the count
  - `clearNavigationBuffer()`: Clear buffer when sync completes
- Updated `beginNavigationCatchUp()` to initialize the buffer

### 2. Modified Sync Logic

**Event Handling** (`MachineController+NavigationSync.swift`)
```swift
case "navigation.changed":
  // ...
  // Buffer events during catch-up to prevent layout shifting
  if connection.isBufferingNavigation() {
    connection.bufferNavigationDelta(delta)
    return  // Don't apply immediately
  }
  // Normal path for post-sync live updates
```

**Atomic Application** (`performNavigationSynchronization`)
After the initial snapshot is loaded and before starting event sync:
1. Check if there are buffered deltas
2. Apply all buffered deltas sequentially to build the final state
3. Commit the final accumulated state in a single `commitSnapshot()` call
4. Apply workspace deltas for proper workspace sync
5. Clear the buffer
6. Start live event streaming from the final cursor position

This ensures:
- No incremental UI updates during catch-up
- Smooth, single transition when sync completes
- All state is consistent when presented to the user

### 3. Visual Feedback

**New `NavigationSyncOverlay` Component** (`HomeNavigationSyncView.swift`)
```swift
struct NavigationSyncOverlay: View {
  let machineName: String
  let bufferedEvents: Int
  // ...
}
```

Features:
- Subtle floating indicator at bottom of screen
- Shows "Syncing" with event count
- Material background with shadow for depth
- Smooth fade-in animation (300ms delay)
- Doesn't block user interaction (`allowsHitTesting(false)`)
- Automatically updates as buffer count changes

**Integration** (`HomeView+Lists.swift`)
- Added `syncOverlayIfCatchingUp` computed property
- Overlays the sync indicator on the existing content when catching up
- Finds the first machine in catch-up state and displays its progress

## Benefits

1. **No Layout Shifting**: Content stays stable during sync, preventing visual jarring
2. **Better UX**: Users see a clear sync progress indicator instead of chaotic reordering
3. **Maintains Focus**: User's scroll position and mental model remain intact
4. **Smooth Transition**: Single atomic update when sync completes
5. **Post-Sync Behavior Unchanged**: Live updates after initial sync still apply immediately for responsiveness

## Testing Strategy

### Unit Tests Updated
- `MachineNavigationSyncTests.swift`: Updated to handle associated value in `.catchingUp`
- `MachineConnectionPresentationTests.swift`: Updated test cases for new enum format

### Manual Testing Checklist
- [ ] Initial app launch with remote machine shows sync overlay
- [ ] Overlay displays correct buffered event count
- [ ] List remains stable during sync (no reordering)
- [ ] Smooth transition when sync completes
- [ ] Live updates work normally after initial sync
- [ ] Multiple machines can sync independently
- [ ] Retry after failed sync works correctly

## Performance Considerations

- **Memory**: Buffer stores deltas temporarily (typically small, cleared quickly)
- **CPU**: Single atomic update is more efficient than N incremental updates
- **Network**: No change to network behavior
- **UI**: Reduces UI work during sync by batching updates

## Edge Cases Handled

1. **Multiple Buffered Events**: All deltas applied in order, maintaining consistency
2. **Out-of-Order Events**: Event cursor checks prevent applying stale events
3. **Task Cancellation**: Proper checks prevent applying stale buffered data
4. **Concurrent Machines**: Each machine manages its own buffer independently
5. **Failed Sync**: Buffer is cleared on retry via `beginNavigationCatchUp()`

## Implementation Notes

- The buffering only applies during the `catchingUp` state
- Once sync completes and state moves to `.current`, live events apply immediately
- This maintains the responsiveness of post-sync live updates
- The overlay uses `@ViewBuilder` to conditionally render based on sync state
- Animation timing (300ms delay, 0.3s spring) balances responsiveness with avoiding flicker

## Related Files

Core Logic:
- `packages/swift/CodevisorCore/Sources/CodevisorCore/Server/NavigationSyncState.swift`
- `packages/swift/CodevisorCore/Sources/CodevisorCore/Server/MachineConnection.swift`
- `packages/swift/CodevisorCore/Sources/CodevisorCore/Server/MachineController+NavigationSync.swift`

UI Components:
- `apps/ios/Codevisor/Features/Home/HomeNavigationSyncView.swift`
- `apps/ios/Codevisor/Features/Home/HomeView+Lists.swift`

Tests:
- `packages/swift/CodevisorCore/Tests/CodevisorCoreTests/MachineNavigationSyncTests.swift`
- `packages/swift/CodevisorUI/Tests/CodevisorUITests/MachineConnectionPresentationTests.swift`
