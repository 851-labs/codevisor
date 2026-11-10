import CodevisorUI
import Observation
import SwiftUI

@MainActor
@Observable
final class WorkspaceInspectorFileTreeFolding {
  struct Placement {
    let progress: CGFloat
    let index: Int
    let count: Int
  }

  private struct Fold {
    var progress: CGFloat
    let generation: Int
  }

  private var folds: [String: Fold] = [:]
  private(set) var revealing: Set<String> = []
  private var generation = 0

  var foldingPaths: [String] { Array(folds.keys) }
  var isIdle: Bool { folds.isEmpty }

  func setExpanded(
    _ path: String, _ isExpanded: Bool, model: WorkspaceInspectorFileTreeModel, reduceMotion: Bool
  ) {
    generation += 1
    let generation = generation
    if isExpanded {
      folds[path] = Fold(progress: 0, generation: generation)
      revealing.insert(path)
      model.setExpanded(path, true)
    } else {
      revealing.remove(path)
      folds[path] = Fold(progress: folds[path]?.progress ?? 1, generation: generation)
      model.setExpanded(path, false)
      withAnimation(Motion.listReflow(reduceMotion: reduceMotion)) { folds[path]?.progress = 0 }
      endFold(path, generation: generation)
    }
  }

  func reveal(model: WorkspaceInspectorFileTreeModel, reduceMotion: Bool) {
    for path in revealing where model.listings[path] != nil || !model.expanded.contains(path) {
      revealing.remove(path)
      guard model.expanded.contains(path), let generation = folds[path]?.generation else {
        folds[path] = nil
        continue
      }
      withAnimation(Motion.listReflow(reduceMotion: reduceMotion)) { folds[path]?.progress = 1 }
      endFold(path, generation: generation)
    }
  }

  func placements(_ rows: [WorkspaceInspectorFileTreeModel.Row]) -> [String: Placement] {
    var placements: [String: Placement] = [:]
    guard !folds.isEmpty else { return placements }
    var index = 0
    while index < rows.count {
      let row = rows[index]
      index += 1
      guard let fold = folds[row.id] else { continue }
      let block = rows[index...].prefix { $0.depth > row.depth }
      for (offset, child) in block.enumerated() {
        placements[child.id] = Placement(progress: fold.progress, index: offset, count: block.count)
      }
      index += block.count
    }
    return placements
  }

  private func endFold(_ path: String, generation: Int) {
    Task {
      try? await Task.sleep(for: .seconds(Motion.listReflowDuration * 2))
      if folds[path]?.generation == generation { folds[path] = nil }
    }
  }
}
