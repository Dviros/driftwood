import Foundation

// Ephemeral "profile" for a natively-launched app: move its real state dirs
// aside before launch, let it run fresh, then restore (discard) or commit
// (keep, archiving the prior state) on close.
//
// Safety invariants (this touches the user's real ~/Library — data loss is the
// enemy):
//   * journal the intent BEFORE each move, atomically;
//   * restore only ever deletes an `orig` path when a matching `stash` exists to
//     put back — so a crash mid-stash can never lose real data;
//   * commit archives the prior real state instead of deleting it;
//   * recoverAll() restores any session left behind by a crash on next launch.
struct StateSwap {
  let bundleID: String
  let appName: String
  let sessionID: String

  var libRoot = NSHomeDirectory() + "/Library"   // overridable for the self-test
  private var lib: String { libRoot }
  private var root: String { lib + "/Application Support/driftwood" }
  private var sessionDir: String { root + "/sessions/" + sessionID }
  private var journalPath: String { sessionDir + "/journal.json" }

  // State locations an app commonly uses, relative to ~/Library.
  private var candidates: [String] {
    ["Containers/\(bundleID)",
     "Application Support/\(appName)",
     "Application Support/\(bundleID)",
     "Preferences/\(bundleID).plist",
     "Caches/\(bundleID)",
     "HTTPStorages/\(bundleID)",
     "HTTPStorages/\(bundleID).binarycookies",
     "WebKit/\(bundleID)",
     "Cookies/\(bundleID).binarycookies",
     "Saved Application State/\(bundleID).savedState"]
  }

  @discardableResult
  func stash() -> Bool {
    let fm = FileManager.default
    try? fm.createDirectory(atPath: sessionDir, withIntermediateDirectories: true)
    var journal: [[String: String]] = []
    for rel in candidates {
      let src = lib + "/" + rel
      guard fm.fileExists(atPath: src) else { continue }
      let dst = sessionDir + "/" + rel.replacingOccurrences(of: "/", with: "_")
      journal.append(["orig": src, "stash": dst])
      writeJournal(journal)                 // record intent BEFORE the move
      try? fm.moveItem(atPath: src, toPath: dst)
    }
    if !journal.isEmpty { flushPrefsCache() }
    return !journal.isEmpty
  }

  /// Discard the session, put the real state back. Crash-safe: only removes an
  /// `orig` when its `stash` is present.
  func restore() {
    let fm = FileManager.default
    for e in readJournal() {
      guard let orig = e["orig"], let stash = e["stash"] else { continue }
      guard fm.fileExists(atPath: stash) else { continue }
      if fm.fileExists(atPath: orig) { try? fm.removeItem(atPath: orig) }
      try? fm.moveItem(atPath: stash, toPath: orig)
    }
    flushPrefsCache()
    try? fm.removeItem(atPath: sessionDir)
  }

  /// Keep the session's state as current; archive the prior real state (never
  /// deleted) so the choice is reversible by hand.
  func commit() {
    let fm = FileManager.default
    let archive = root + "/archive"
    try? fm.createDirectory(atPath: archive, withIntermediateDirectories: true)
    try? fm.moveItem(atPath: sessionDir, toPath: archive + "/" + sessionID)
  }

  /// On startup, restore anything a crash left mid-session.
  static func recoverAll() {
    let sessions = NSHomeDirectory() + "/Library/Application Support/driftwood/sessions"
    guard let sids = try? FileManager.default.contentsOfDirectory(atPath: sessions) else { return }
    for sid in sids { StateSwap(bundleID: "", appName: "", sessionID: sid).restore() }
  }

  // cfprefsd caches preferences and would rewrite the plist we moved; bounce it.
  private func flushPrefsCache() {
    guard libRoot == NSHomeDirectory() + "/Library" else { return }   // never during self-test
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
    p.arguments = ["cfprefsd"]
    try? p.run(); p.waitUntilExit()
  }

  private func writeJournal(_ j: [[String: String]]) {
    guard let d = try? JSONSerialization.data(withJSONObject: j) else { return }
    let tmp = journalPath + ".tmp"
    try? d.write(to: URL(fileURLWithPath: tmp))
    _ = try? FileManager.default.replaceItemAt(URL(fileURLWithPath: journalPath),
                                               withItemAt: URL(fileURLWithPath: tmp))
    if FileManager.default.fileExists(atPath: tmp) {   // replaceItemAt failed (no original yet)
      try? FileManager.default.moveItem(atPath: tmp, toPath: journalPath)
    }
  }

  private func readJournal() -> [[String: String]] {
    guard let d = try? Data(contentsOf: URL(fileURLWithPath: journalPath)),
          let j = try? JSONSerialization.jsonObject(with: d) as? [[String: String]] else { return [] }
    return j
  }

  // Headless check of the data-critical primitive against synthetic dirs
  // (run: `Driftwood selftest`). Never touches the real ~/Library.
  static func runSelfTest() {
    let fm = FileManager.default
    let lib = NSTemporaryDirectory() + "dw-selftest-" + UUID().uuidString + "/Library"
    let pref = lib + "/Preferences/com.test.app.plist"
    let data = lib + "/Application Support/TestApp/data.txt"
    try? fm.createDirectory(atPath: lib + "/Preferences", withIntermediateDirectories: true)
    try? fm.createDirectory(atPath: lib + "/Application Support/TestApp", withIntermediateDirectories: true)
    try? "REAL".write(toFile: pref, atomically: true, encoding: .utf8)
    try? "REAL".write(toFile: data, atomically: true, encoding: .utf8)

    var sw = StateSwap(bundleID: "com.test.app", appName: "TestApp", sessionID: "selftest")
    sw.libRoot = lib
    let stashed = sw.stash()
    let fresh = !fm.fileExists(atPath: pref) && !fm.fileExists(atPath: data)   // app sees empty state
    try? "SESSION".write(toFile: pref, atomically: true, encoding: .utf8)      // app writes its own
    try? fm.createDirectory(atPath: lib + "/Application Support/TestApp", withIntermediateDirectories: true)
    try? "SESSION".write(toFile: data, atomically: true, encoding: .utf8)
    sw.restore()                                                               // ephemeral: revert
    let ok = (try? String(contentsOfFile: pref)) == "REAL"
          && (try? String(contentsOfFile: data)) == "REAL"
    try? fm.removeItem(atPath: NSString(string: lib).deletingLastPathComponent)

    let pass = stashed && fresh && ok
    FileHandle.standardError.write(
      "SELFTEST stashed=\(stashed) fresh=\(fresh) restored=\(ok) => \(pass ? "PASS" : "FAIL")\n".data(using: .utf8)!)
    exit(pass ? 0 : 1)
  }
}
