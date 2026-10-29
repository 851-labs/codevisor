struct BenchUDPDatagram {
  let bytes: [UInt8]
  let sender: BenchUDPAddress
  let receivedNs: Int64
}
