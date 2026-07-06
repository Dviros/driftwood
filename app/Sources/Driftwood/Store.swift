import SwiftUI
import AppKit

enum Source: String, CaseIterable, Hashable {
  case appStore = "App Store"
  case system = "System"
  case user = "User (~)"
  case other = "Applications"
}

enum Policy: String, CaseIterable, Identifiable {
  case casual = "Casual"          // ephemeral state-swap, native launch
  case persistent = "Persistent"  // native launch, no swap (changes kept)
  case paranoid = "Paranoid"      // isolated VM (requires a golden image)
  var id: String { rawValue }
  var blurb: String {
    switch self {
    case .casual:     return "Fresh throwaway profile; wiped on close (native launch)."
    case .persistent: return "Normal launch; the app's changes are kept."
    case .paranoid:   return "Isolated VM with rotated serial/MAC — needs a golden image."
    }
  }
}

struct InstalledApp: Identifiable, Hashable {
  let id = UUID()
  let name: String
  let path: String
  let bundleID: String
  let source: Source
  var icon: NSImage { NSWorkspace.shared.icon(forFile: path) }
}

struct AppGroup: Identifiable { let id: Source; let apps: [InstalledApp] }

struct Metrics: Equatable { var cpu: Double = 0; var memMB: Double = 0 }

final class Store: ObservableObject {
  @Published var apps: [InstalledApp] = []
  @Published var query = ""
  @Published var policy: Policy = .casual
  @Published var askOnClose = false
  @Published var running: Set<UUID> = []
  @Published var metrics: [UUID: Metrics] = [:]
  @Published var message = ""

  private var pidForApp: [UUID: pid_t] = [:]
  private var swapForApp: [UUID: StateSwap] = [:]
  private var timer: Timer?

  init() {
    StateSwap.recoverAll()          // undo anything a crash left mid-session
    rescan()
    NSWorkspace.shared.notificationCenter.addObserver(
      self, selector: #selector(appTerminated(_:)),
      name: NSWorkspace.didTerminateApplicationNotification, object: nil)
    timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.sample() }
  }

  // MARK: presentation
  var filtered: [InstalledApp] {
    query.isEmpty ? apps : apps.filter { $0.name.localizedCaseInsensitiveContains(query) }
  }
  func grouped() -> [AppGroup] {
    Source.allCases.compactMap { src in
      let items = filtered.filter { $0.source == src }
      return items.isEmpty ? nil : AppGroup(id: src, apps: items)
    }
  }
  func isRunning(_ app: InstalledApp) -> Bool { running.contains(app.id) }

  // MARK: discovery
  func rescan() {
    let home = NSHomeDirectory()
    let dirs = ["/Applications", "/Applications/Utilities",
                "/System/Applications", "/System/Applications/Utilities",
                home + "/Applications"]
    let fm = FileManager.default
    var seen = Set<String>(); var out: [InstalledApp] = []
    for dir in dirs {
      guard let items = try? fm.contentsOfDirectory(atPath: dir) else { continue }
      for item in items where item.hasSuffix(".app") {
        let path = dir + "/" + item
        guard seen.insert(path).inserted else { continue }
        let name = String(item.dropLast(4))
        let bid = bundleID(path) ?? "unknown.\(name)"
        out.append(InstalledApp(name: name, path: path, bundleID: bid, source: source(path, home: home)))
      }
    }
    apps = out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
  }

  // MARK: lifecycle
  func toggle(_ app: InstalledApp) { isRunning(app) ? stop(app) : launch(app) }

  func launch(_ app: InstalledApp) {
    message = ""
    guard NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID).isEmpty else {
      message = "\(app.name) is already running — quit it first to sandbox it."; return
    }
    switch policy {
    case .paranoid:
      message = "Paranoid = disposable VM. Build a golden first: driftwood run --macos (see README)."
    case .persistent:
      openNative(app, swap: nil)
    case .casual:
      let sw = StateSwap(bundleID: app.bundleID, appName: app.name, sessionID: UUID().uuidString)
      sw.stash()
      swapForApp[app.id] = sw
      openNative(app, swap: sw)
    }
  }

  private func openNative(_ app: InstalledApp, swap: StateSwap?) {
    let cfg = NSWorkspace.OpenConfiguration()
    cfg.createsNewApplicationInstance = false
    NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: app.path), configuration: cfg) { [weak self] run, err in
      DispatchQueue.main.async {
        guard let self else { return }
        if let run {
          self.pidForApp[app.id] = run.processIdentifier
          self.metrics[app.id] = Metrics()
          self.running.insert(app.id)
        } else {
          self.message = "Failed to launch \(app.name): \(err?.localizedDescription ?? "unknown")"
          swap?.restore()
          self.swapForApp[app.id] = nil
        }
      }
    }
  }

  func stop(_ app: InstalledApp) {
    if let ra = NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID).first {
      ra.terminate()          // didTerminate notification drives cleanup
    } else {
      finish(app.id)
    }
  }

  @objc private func appTerminated(_ note: Notification) {
    guard let ra = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
          let bid = ra.bundleIdentifier,
          let app = apps.first(where: { $0.bundleID == bid && running.contains($0.id) }) else { return }
    finish(app.id)
  }

  private func finish(_ appID: UUID) {
    guard running.contains(appID) else { return }
    running.remove(appID); metrics[appID] = nil; pidForApp[appID] = nil
    guard let sw = swapForApp[appID] else { return }
    swapForApp[appID] = nil
    if askOnClose { askKeepOrDiscard(appID, sw) } else { sw.restore() }
  }

  private func askKeepOrDiscard(_ appID: UUID, _ swap: StateSwap) {
    let name = apps.first(where: { $0.id == appID })?.name ?? "this app"
    let a = NSAlert()
    a.messageText = "Keep \(name)'s session data?"
    a.informativeText = "Discard reverts to your real profile. Keep makes this session current (your prior profile is archived, not deleted)."
    a.addButton(withTitle: "Discard"); a.addButton(withTitle: "Keep")
    if a.runModal() == .alertFirstButtonReturn { swap.restore() } else { swap.commit() }
  }

  // MARK: monitoring (main process; helper procs of Electron apps not summed yet)
  private func sample() {
    guard !pidForApp.isEmpty else { return }
    for (appID, pid) in pidForApp {
      if let m = ps(pid) { metrics[appID] = m }
    }
  }
  private func ps(_ pid: pid_t) -> Metrics? {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/ps")
    p.arguments = ["-o", "%cpu=,rss=", "-p", "\(pid)"]
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
    do { try p.run() } catch { return nil }
    let out = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
    let cols = (String(data: out, encoding: .utf8) ?? "")
      .split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
    guard cols.count >= 2, let cpu = Double(cols[0]), let rss = Double(cols[1]) else { return nil }
    return Metrics(cpu: cpu, memMB: rss / 1024)
  }

  // MARK: classification
  private func bundleID(_ appPath: String) -> String? {
    NSDictionary(contentsOfFile: appPath + "/Contents/Info.plist")?["CFBundleIdentifier"] as? String
  }
  private func source(_ path: String, home: String) -> Source {
    if FileManager.default.fileExists(atPath: path + "/Contents/_MASReceipt/receipt") { return .appStore }
    if path.hasPrefix("/System/") { return .system }
    if path.hasPrefix(home) { return .user }
    return .other
  }
}
