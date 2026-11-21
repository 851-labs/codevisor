enum FirstLaunchWait: Hashable {
  case server
  case step(FirstLaunchStep)
}
