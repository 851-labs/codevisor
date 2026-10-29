import ScreenSharingBench

struct RelayDelivery: Sendable {
  let socket: RelaySocket
  let destination: BenchUDPAddress
  let bytes: [UInt8]

  func send() -> Bool {
    socket.send(bytes, to: destination)
  }
}
