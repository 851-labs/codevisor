enum ScreenSharingVCPReceipt {
  case encoded(ScreenSharingVCPSubmission)
  case skipped(ScreenSharingVCPSubmission, unchanged: Bool)
  case failed(ScreenSharingVCPSubmission)
}
