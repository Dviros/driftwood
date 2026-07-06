import SwiftUI
import Foundation

enum VMState: Equatable {
  case checking
  case noGolden
  case downloading(Double)   // 0...1, or -1 for indeterminate
  case ready
}

// Network modes that tart actually enforces at the VM boundary.
enum NetMode: String, CaseIterable, Identifiable {
  case full = "Full"          // default shared NAT — internet access
  case isolated = "Isolated"  // softnet — isolated from the host LAN
  var id: String { rawValue }
  var runArgs: [String] {
    switch self {
    case .full:     return []              // tart's default shared networking
    case .isolated: return ["--net-softnet"]
    }
  }
  // Split-tunnel + true-offline are roadmap: they need a Tor/VPN gateway VM or
  // softnet deny-rules, not a single flag.
}

final class VMManager: ObservableObject {
  static let golden = "driftwood-golden"
  static let image  = "ghcr.io/cirruslabs/macos-sequoia-vanilla:latest"

  @Published var state: VMState = .checking
  @Published var netMode: NetMode = .isolated
  @Published var message = ""

  private var download: Process?

  func refresh() {
    state = (run(["list"]) ?? "").contains(Self.golden) ? .ready : .noGolden
  }

  /// Pull the golden once (~tens of GB, APFS CoW so every clone after is free).
  func downloadGolden() {
    guard state == .noGolden else { return }
    state = .downloading(-1)
    let p = Process()
    p.executableURL = URL(fileURLWithPath: tart)
    p.arguments = ["clone", Self.image, Self.golden]
    let out = Pipe(); p.standardOutput = out; p.standardError = out
    out.fileHandleForReading.readabilityHandler = { [weak self] h in
      let chunk = String(data: h.availableData, encoding: .utf8) ?? ""
      guard let pct = Self.percent(chunk) else { return }
      DispatchQueue.main.async { if case .downloading = self?.state { self?.state = .downloading(pct) } }
    }
    p.terminationHandler = { [weak self] proc in
      DispatchQueue.main.async {
        out.fileHandleForReading.readabilityHandler = nil
        self?.refresh()
        if proc.terminationStatus != 0 { self?.message = "Golden download stopped." }
      }
    }
    do { try p.run(); download = p } catch { state = .noGolden; message = "Couldn't start tart." }
  }

  func cancelDownload() {
    download?.terminate(); download = nil
    _ = run(["delete", Self.golden])
    refresh()
  }

  /// Disposable session: linked clone → rotate serial+MAC → mount the app → run
  /// → destroy on window close. EXPERIMENTAL: whether a host .app runs from the
  /// mounted share depends on the app (frameworks / signing / installers).
  func launch(appPath: String, appName: String) {
    guard state == .ready else { message = "Download the golden image first."; return }
    let clone = "dw-" + UUID().uuidString.prefix(8)
    guard run(["clone", Self.golden, clone]) != nil else { message = "Linked clone failed."; return }
    _ = run(["set", clone, "--random-mac", "--random-serial"])

    let p = Process()
    p.executableURL = URL(fileURLWithPath: tart)
    p.arguments = ["run"] + netMode.runArgs + ["--dir=app:\(appPath):ro", clone]
    p.terminationHandler = { [weak self] _ in
      DispatchQueue.global().async { _ = self?.run(["delete", clone]) }   // destroy on close
    }
    do { try p.run(); message = "Launched \(appName) in a disposable VM (\(netMode.rawValue) net)." }
    catch { _ = run(["delete", clone]); message = "Couldn't start the VM." }
  }

  // MARK: helpers
  private var tart: String {
    ["/opt/homebrew/bin/tart", "/usr/local/bin/tart"]
      .first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/opt/homebrew/bin/tart"
  }
  @discardableResult
  private func run(_ args: [String]) -> String? {
    let p = Process(); p.executableURL = URL(fileURLWithPath: tart); p.arguments = args
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
    do { try p.run() } catch { return nil }
    let d = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
    return p.terminationStatus == 0 ? (String(data: d, encoding: .utf8) ?? "") : nil
  }
  static func percent(_ s: String) -> Double? {
    guard let r = s.range(of: #"\d{1,3}%"#, options: .regularExpression) else { return nil }
    return Double(s[r].dropLast()).map { $0 / 100 }
  }
}
