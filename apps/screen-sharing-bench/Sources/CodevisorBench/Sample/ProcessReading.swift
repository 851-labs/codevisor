struct ProcessReading: Sendable, Equatable {
  let sampledNs: Int64
  let cpuNs: Int64
  let energyNj: Int64?
}
