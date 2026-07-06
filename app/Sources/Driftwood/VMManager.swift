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

  /// Disposable session: linked clone → rotate serial+MAC → boot → launch the
  /// app INSIDE the guest (by name if it's in the golden, else copy the bundle
  /// in) → destroy on window close. Verified: SSH `open -a` launches guest apps.
  func launch(appPath: String, appName: String, isAppStore: Bool) {
    guard state == .ready else { message = "Download the golden image first."; return }
    let clone = "dw-" + UUID().uuidString.prefix(8)
    guard run(["clone", Self.golden, clone]) != nil else { message = "Linked clone failed."; return }
    // App Store receipts are bound to the machine identity — rotating it makes
    // strict apps reject the receipt (exit 173). Keep the golden's identity for
    // those; rotate for everything else.
    if !isAppStore { _ = run(["set", clone, "--random-mac", "--random-serial"]) }

    let p = Process()
    p.executableURL = URL(fileURLWithPath: tart)
    p.arguments = ["run"] + netMode.runArgs + [clone]
    p.terminationHandler = { [weak self] _ in
      DispatchQueue.global().async { _ = self?.run(["delete", clone]) }   // destroy on close
    }
    do { try p.run() } catch { _ = run(["delete", clone]); message = "Couldn't start the VM."; return }
    message = "Booting a disposable VM for \(appName)…"

    DispatchQueue.global().async { [weak self] in
      guard let self else { return }
      guard let ip = self.waitIP(clone) else {
        DispatchQueue.main.async { self.message = "VM up but no network yet — open \(appName) from inside the VM." }
        return
      }
      var ok = self.ssh(ip, "open -a \"\(appName)\" && echo DW_OK")   // installed in the golden?
      if !ok && !isAppStore {                                          // copy in (non-MAS only)
        _ = self.scp(ip, appPath)
        ok = self.ssh(ip, "open \"/Users/admin/\((appPath as NSString).lastPathComponent)\" && echo DW_OK")
      }
      DispatchQueue.main.async {
        if ok {
          self.message = "\(appName) launched inside disposable VM \(clone) (\(self.netMode.rawValue) net)."
        } else if isAppStore {
          self.message = "\(appName) isn't in the golden yet — click ‘Manage golden’, sign into the App Store, install it, then shut down. Clones will run it."
        } else {
          self.message = "\(appName) wouldn't run in the guest — install it in the golden (Manage golden)."
        }
      }
    }
  }

  /// Open the golden read-write and land on the App Store so the user installs
  /// their apps once; every disposable clone then has them (receipt included).
  func manageGolden() {
    let p = Process(); p.executableURL = URL(fileURLWithPath: tart); p.arguments = ["run", Self.golden]
    do { try p.run() } catch { message = "Couldn't open the golden."; return }
    message = "Golden booting — the App Store will open. Sign in, install your apps, then shut it down."
    DispatchQueue.global().async { [weak self] in
      guard let self, let ip = self.waitIP(Self.golden) else { return }
      _ = self.ssh(ip, "open -a \"App Store\"")
    }
  }

  private func waitIP(_ clone: String) -> String? {
    let ip = run(["ip", clone, "--wait", "120"])?.trimmingCharacters(in: .whitespacesAndNewlines)
    return (ip?.isEmpty == false) ? ip : nil
  }
  @discardableResult private func ssh(_ ip: String, _ remote: String) -> Bool {
    expectRun("ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null admin@\(ip) {\(remote)}").contains("DW_OK")
  }
  @discardableResult private func scp(_ ip: String, _ path: String) -> Bool {
    let out = expectRun("scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -r \"\(path)\" admin@\(ip):/Users/admin/")
    return !out.lowercased().contains("denied")
  }
  private func expectRun(_ spawnLine: String) -> String {
    let script = """
    set timeout 90
    spawn \(spawnLine)
    expect {
      -re {[Pp]assword:} { send \"admin\\r\"; exp_continue }
      -re {yes/no} { send \"yes\\r\"; exp_continue }
      timeout { exit 1 }
      eof
    }
    """
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/expect"); p.arguments = ["-c", script]
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
    do { try p.run() } catch { return "" }
    let d = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
    return String(data: d, encoding: .utf8) ?? ""
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
