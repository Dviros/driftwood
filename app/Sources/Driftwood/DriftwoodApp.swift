import SwiftUI

// Native launcher: lists installed apps and runs each under a policy — Casual
// (ephemeral ~/Library state-swap), Persistent (plain launch), or Paranoid
// (disposable macOS VM). No macros, so it builds with Command Line Tools alone
// — no full Xcode required.
@main
struct DriftwoodApp: App {
  @StateObject private var store = Store()
  @StateObject private var vm = VMManager()
  init() {
    if CommandLine.arguments.dropFirst().contains("selftest") { StateSwap.runSelfTest() }
  }
  var body: some Scene {
    WindowGroup {
      ContentView()
        .environmentObject(store)
        .environmentObject(vm)
        .onAppear { store.vm = vm; vm.refresh() }
        .frame(minWidth: 900, minHeight: 500)
    }
    .windowStyle(.hiddenTitleBar)
  }
}
