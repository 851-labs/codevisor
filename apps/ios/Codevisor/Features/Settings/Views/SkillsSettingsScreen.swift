import CodevisorCore
import CodevisorUI
import SwiftUI

// MARK: - Skills

/// The Skills screen: a machine list that pushes each machine's skill
/// store; the fleet ferries skill content between machines.
struct SkillsSettingsScreen: View {
  @Environment(AppEnvironment.self) private var environment
  /// Each machine's scanned skill directory names, fetched per machine so
  /// the badge can compare against the fleet's synced skill set instead of
  /// guessing from reachability.
  @State private var scannedSkillsByMachine: [String: Set<String>] = [:]

  var body: some View {
    let machines = environment.machines.allMachines
    Group {
      if machines.count == 1, let only = machines.first {
        SkillMachineScreen(machine: only, title: "Skills")
          .id(only.id)
      } else {
        machineList
      }
    }
  }

  private var machineList: some View {
    List {
      Section {
        ForEach(environment.machines.allMachines) { machine in
          NavigationLink {
            SkillMachineScreen(machine: machine, title: machine.name)
          } label: {
            HStack {
              Text(machine.name)
              Spacer(minLength: 12)
              badge(machine).view
                .font(.footnote)
            }
          }
        }
      }
    }
    .navigationTitle("Skills")
    .navigationBarTitleDisplayMode(.inline)
    .task(id: environment.machines.allMachines.map(\.id)) { await scanAllMachines() }
    .onChange(of: environment.configSync.revisionsByNamespace["skills"]) { _, _ in
      Task { await scanAllMachines() }
    }
  }

  /// The badge tells the truth per machine: a machine missing skills the
  /// fleet carries is still syncing, not "Synced".
  private func badge(_ machine: CodevisorMachine) -> MachineSyncBadge {
    if environment.machines.statusByMachineId[machine.id]?.isReachable == false {
      return .attention("Unreachable")
    }
    let fleetSkills = Set(
      environment.configSync.entries(namespace: "skills")
        .filter { $0.deleted != true }
        .map(\.key)
    )
    guard let scanned = scannedSkillsByMachine[machine.id] else { return .syncing }
    return fleetSkills.isSubset(of: scanned) ? .synced : .syncing
  }

  private func scanAllMachines() async {
    await withTaskGroup(of: (String, Set<String>?).self) { group in
      for machine in environment.machines.allMachines {
        let client = environment.machines.client(for: machine.id)
        group.addTask { @MainActor in
          let scan = try? await client.listSkills()
          return (machine.id, scan.map { Set($0.global.map(\.directoryName)) })
        }
      }
      for await (machineId, skills) in group {
        scannedSkillsByMachine[machineId] = skills
      }
    }
  }
}
