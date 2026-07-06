import Foundation

// Full visibility into everything driftwood leaves on the host, plus a safe
// purge. The honest "no hidden logs": we can't stop macOS's unified log from
// recording a native app launch — no unprivileged tool can — but we can show
// exactly what *driftwood* itself puts on disk and wipe the orphans.
enum Traces {
  static let root = NSHomeDirectory() + "/Library/Application Support/driftwood"

  struct Report {
    var activeSessions: Int   // real state stashed for a running Casual app (protected)
    var archives: Int         // prior profiles kept by "commit" (protected backups)
    var tempHomes: Int        // orphaned sandbox homes (safe to remove)
    var vmClones: [String]    // leftover disposable VM clones (safe to remove)
    var orphans: Int { tempHomes + vmClones.count }
  }

  static func scan() -> Report {
    let fm = FileManager.default
    let sessions = (try? fm.contentsOfDirectory(atPath: root + "/sessions").count) ?? 0
    let archives = (try? fm.contentsOfDirectory(atPath: root + "/archive").count) ?? 0
    let temp = ((try? fm.contentsOfDirectory(atPath: NSTemporaryDirectory())) ?? [])
      .filter { $0.hasPrefix("dw-sbx.") }.count
    return Report(activeSessions: sessions, archives: archives, tempHomes: temp, vmClones: tartClones())
  }

  /// Remove only the clearly-safe orphans: stray temp homes + leftover VM clones.
  /// Never touches active sessions (would lose real data) or commit archives.
  static func purgeOrphans() {
    let fm = FileManager.default
    for f in ((try? fm.contentsOfDirectory(atPath: NSTemporaryDirectory())) ?? [])
      where f.hasPrefix("dw-sbx.") {
      try? fm.removeItem(atPath: NSTemporaryDirectory() + f)
    }
    for clone in tartClones() { runTart(["delete", clone]) }
  }

  static func tartClones() -> [String] {
    guard let out = runTart(["list"]) else { return [] }
    var names: [String] = []
    for line in out.split(separator: "\n") {
      for tok in line.split(separator: " ") where tok.hasPrefix("dw-") { names.append(String(tok)) }
    }
    return names
  }

  @discardableResult
  private static func runTart(_ args: [String]) -> String? {
    guard let tart = ["/opt/homebrew/bin/tart", "/usr/local/bin/tart"]
      .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return nil }
    let p = Process(); p.executableURL = URL(fileURLWithPath: tart); p.arguments = args
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
    do { try p.run() } catch { return nil }
    let d = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
    return String(data: d, encoding: .utf8)
  }
}
