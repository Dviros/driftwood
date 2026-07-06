import SwiftUI
import AppKit

struct InstalledApp: Identifiable, Hashable {
  let id = UUID()
  let name: String
  let path: String
  var icon: NSImage { NSWorkspace.shared.icon(forFile: path) }
}

private struct Session {
  let appID: UUID
  let process: Process
  let home: String
}

/// Scans installed apps and runs each in a throwaway `sandbox-exec` jail.
final class Store: ObservableObject {
  @Published var apps: [InstalledApp] = []
  @Published var runningAppIDs: Set<UUID> = []
  @Published var noNet = false
  @Published var query = ""

  private var sessions: [UUID: Session] = [:]      // sessionID -> Session
  private var sessionForApp: [UUID: UUID] = [:]    // appID -> sessionID

  init() { rescan() }

  var filtered: [InstalledApp] {
    query.isEmpty ? apps
      : apps.filter { $0.name.localizedCaseInsensitiveContains(query) }
  }

  func isRunning(_ app: InstalledApp) -> Bool { runningAppIDs.contains(app.id) }
  func toggle(_ app: InstalledApp) { isRunning(app) ? stop(app) : launch(app) }

  func rescan() {
    let dirs = ["/Applications", "/Applications/Utilities",
                "/System/Applications", "/System/Applications/Utilities",
                NSHomeDirectory() + "/Applications"]
    let fm = FileManager.default
    var seen = Set<String>()
    var out: [InstalledApp] = []
    for dir in dirs {
      guard let items = try? fm.contentsOfDirectory(atPath: dir) else { continue }
      for item in items where item.hasSuffix(".app") {
        let name = String(item.dropLast(4))
        if seen.insert(name).inserted {
          out.append(InstalledApp(name: name, path: dir + "/" + item))
        }
      }
    }
    apps = out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
  }

  func launch(_ app: InstalledApp) {
    guard let bin = executable(for: app.path) else { return }
    let home = NSTemporaryDirectory() + "dw-sbx." + String(UUID().uuidString.prefix(8))
    try? FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)

    let profile = home + "/profile.sb"
    var sb = "(version 1)\n(allow default)\n(deny file-write* (subpath \"\(NSHomeDirectory())\"))\n"
    if noNet { sb += "(deny network*)\n" }
    try? sb.write(toFile: profile, atomically: true, encoding: .utf8)

    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
    proc.arguments = ["-f", profile, bin]
    var env = ProcessInfo.processInfo.environment
    env["HOME"] = home
    proc.environment = env

    let sid = UUID()
    proc.terminationHandler = { [weak self] _ in
      DispatchQueue.main.async { self?.finished(sid) }
    }
    do { try proc.run() }
    catch { try? FileManager.default.removeItem(atPath: home); return }

    sessions[sid] = Session(appID: app.id, process: proc, home: home)
    sessionForApp[app.id] = sid
    runningAppIDs.insert(app.id)
  }

  func stop(_ app: InstalledApp) {
    guard let sid = sessionForApp[app.id], let s = sessions[sid] else { return }
    s.process.terminate()   // finished() runs from the termination handler
  }

  private func finished(_ sid: UUID) {
    guard let s = sessions[sid] else { return }
    try? FileManager.default.removeItem(atPath: s.home)
    sessions[sid] = nil
    sessionForApp[s.appID] = nil
    runningAppIDs.remove(s.appID)
  }

  private func executable(for appPath: String) -> String? {
    guard let dict = NSDictionary(contentsOfFile: appPath + "/Contents/Info.plist"),
          let exe = dict["CFBundleExecutable"] as? String else { return nil }
    let bin = appPath + "/Contents/MacOS/" + exe
    return FileManager.default.isExecutableFile(atPath: bin) ? bin : nil
  }
}
