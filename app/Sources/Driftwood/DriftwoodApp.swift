import SwiftUI

// Native launcher: shows your installed apps and runs each in a disposable
// Seatbelt sandbox (fresh throwaway $HOME, wiped on close). No macros, so it
// builds with Command Line Tools alone — no full Xcode required.
@main
struct DriftwoodApp: App {
  @StateObject private var store = Store()
  init() {
    if CommandLine.arguments.dropFirst().contains("selftest") { StateSwap.runSelfTest() }
  }
  var body: some Scene {
    WindowGroup {
      ContentView()
        .environmentObject(store)
        .frame(minWidth: 760, minHeight: 500)
    }
    .windowStyle(.hiddenTitleBar)
  }
}
