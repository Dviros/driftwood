import SwiftUI

struct ContentView: View {
  @EnvironmentObject var store: Store
  @EnvironmentObject var vm: VMManager
  @State private var showInspector = false
  private let cols = [GridItem(.adaptive(minimum: 142), spacing: 16)]

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider().opacity(0.3)
      goldenBar
      if !store.message.isEmpty {
        Text(store.message)
          .font(.caption).foregroundStyle(.orange)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 20).padding(.vertical, 7)
          .background(.orange.opacity(0.10))
      }
      ScrollView {
        VStack(alignment: .leading, spacing: 24) {
          ForEach(store.grouped()) { group in
            VStack(alignment: .leading, spacing: 12) {
              HStack(spacing: 6) {
                Text(group.id.rawValue).font(.headline)
                Text("\(group.apps.count)").font(.caption).foregroundStyle(.secondary)
              }
              LazyVGrid(columns: cols, spacing: 16) {
                ForEach(group.apps) { app in
                  AppCard(app: app, running: store.isRunning(app),
                          metrics: store.metrics[app.id],
                          override: store.appPolicy[app.bundleID]) {
                    store.toggle(app)
                  }
                  .contextMenu {
                    Text("Policy — \(app.name)")
                    Button("Use default (\(store.policy.rawValue))") { store.setPolicy(nil, forBundle: app.bundleID) }
                    ForEach(Policy.allCases) { p in
                      Button(p.rawValue + (store.appPolicy[app.bundleID] == p ? "  ✓" : "")) {
                        store.setPolicy(p, forBundle: app.bundleID)
                      }
                    }
                    Divider()
                    Text("Data")
                    Button("Use default (\(store.dataMode.rawValue))") { store.setDataMode(nil, forBundle: app.bundleID) }
                    ForEach(DataMode.allCases) { d in
                      Button(d.rawValue + (store.appDataMode[app.bundleID] == d ? "  ✓" : "")) {
                        store.setDataMode(d, forBundle: app.bundleID)
                      }
                    }
                  }
                }
              }
            }
          }
        }
        .padding(20)
      }
    }
    .background(VisualEffect().ignoresSafeArea())
    .sheet(isPresented: $showInspector) { InspectorView().environmentObject(store) }
  }

  private var header: some View {
    HStack(spacing: 12) {
      Image(systemName: "shield.lefthalf.filled").font(.title3)
        .foregroundStyle(.teal).symbolRenderingMode(.hierarchical)
      Text("driftwood").font(.headline)
      if store.running.count > 0 {
        Text("\(store.running.count) sandboxed").font(.caption2.weight(.semibold))
          .foregroundStyle(.green)
          .padding(.horizontal, 7).padding(.vertical, 2)
          .background(Capsule().fill(.green.opacity(0.15)))
      }
      Spacer()
      Picker("", selection: $store.policy) {
        ForEach(Policy.allCases) { Text($0.rawValue).tag($0) }
      }
      .pickerStyle(.segmented).frame(width: 228).help(store.policy.blurb)
      Picker("", selection: $store.dataMode) {
        ForEach(DataMode.allCases) { Label($0.rawValue, systemImage: $0 == .blank ? "sparkles" : "doc.on.doc").tag($0) }
      }
      .pickerStyle(.menu).frame(width: 118).help("Blank = from scratch · Cloned = a throwaway copy of your real data (logged in), discarded on close")
      Toggle("Ask on close", isOn: $store.askOnClose).toggleStyle(.checkbox).controlSize(.small)
      TextField("Search", text: $store.query).textFieldStyle(.roundedBorder).frame(width: 150)
      Button { showInspector = true } label: { Image(systemName: "chart.bar.xaxis") }
        .buttonStyle(.borderless).help("Activity / inspector")
      Button { store.rescan() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless)
    }
    .padding(.horizontal, 20).padding(.vertical, 12)
    .background(.ultraThinMaterial)
  }

  @ViewBuilder private var goldenBar: some View {
    if store.policy == .paranoid {
      HStack(spacing: 12) {
        switch vm.state {
        case .checking:
          ProgressView().controlSize(.small)
          Text("checking VM engine…").font(.caption)
        case .noGolden:
          Image(systemName: "cube.transparent").foregroundStyle(.blue)
          Text("Paranoid runs each app in a disposable VM — needs a golden image once.").font(.caption)
          Button("Download golden (~25 GB)") { vm.downloadGolden() }.controlSize(.small)
        case .downloading(let p):
          if p < 0 { ProgressView().controlSize(.small) } else { ProgressView(value: p).frame(width: 150) }
          Text(p < 0 ? "starting…" : "\(Int(p * 100))%").font(.caption).monospacedDigit()
          Button("Cancel") { vm.cancelDownload() }.controlSize(.small)
        case .ready:
          Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
          Text("Golden ready — apps open in a throwaway VM (rotated serial/MAC).").font(.caption)
          Button("Manage golden") { vm.manageGolden() }.controlSize(.small)
          Spacer(minLength: 8)
          Label("Network", systemImage: "network").labelStyle(.iconOnly).foregroundStyle(.secondary)
          Picker("", selection: $vm.net) {
            ForEach(vm.netChoices) { Label($0.label, systemImage: $0.icon).tag($0) }
          }.pickerStyle(.menu).frame(width: 148)
          .help("Full · Isolated · Offline · route the VM through a native VPN (Tailscale / ProtonVPN / WireGuard)")
        }
        Spacer()
      }
      .padding(.horizontal, 20).padding(.vertical, 8)
      .background(.blue.opacity(0.06))
    }
  }
}

struct AppCard: View {
  let app: InstalledApp
  let running: Bool
  let metrics: Metrics?
  let override: Policy?
  let action: () -> Void
  @State private var hover = false

  var body: some View {
    Button(action: action) {
      VStack(spacing: 8) {
        ZStack(alignment: .topTrailing) {
          Image(nsImage: app.icon).resizable().frame(width: 52, height: 52)
          if running {
            Circle().fill(.green).frame(width: 11, height: 11)
              .overlay(Circle().strokeBorder(.white.opacity(0.85)))
              .offset(x: 4, y: -4)
          }
        }
        Text(app.name).font(.callout).lineLimit(1).foregroundStyle(.primary)
        if let override {
          Text(override.rawValue).font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(Capsule().fill(Color.blue.opacity(0.22)))
        }
        if running {
          Text(metrics.map { String(format: "%.0f%% · %.0f MB", $0.cpu, $0.memMB) } ?? "…")
            .font(.caption2).monospacedDigit().foregroundStyle(.green)
          Text("click to close").font(.caption2).foregroundStyle(.secondary)
        } else {
          Text("click to launch").font(.caption2).foregroundStyle(.secondary)
        }
      }
      .frame(maxWidth: .infinity).padding(.vertical, 16).padding(.horizontal, 6)
      .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
      .overlay(RoundedRectangle(cornerRadius: 16)
        .strokeBorder(running ? Color.green.opacity(0.7) : Color.white.opacity(0.12), lineWidth: 1))
      .shadow(color: .black.opacity(hover ? 0.28 : 0.12), radius: hover ? 11 : 5, y: 3)
      .scaleEffect(hover ? 1.03 : 1)
    }
    .buttonStyle(.plain).onHover { hover = $0 }
    .animation(.easeOut(duration: 0.15), value: hover)
    .animation(.easeOut(duration: 0.20), value: running)
    .help(app.path)
  }
}

struct InspectorView: View {
  @EnvironmentObject var store: Store
  @Environment(\.dismiss) private var dismiss
  @State private var report = Traces.Report(activeSessions: 0, archives: 0, tempHomes: 0, vmClones: [])

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Text("Activity & traces").font(.headline)
        Text("\(store.running.count) running").font(.caption).foregroundStyle(.secondary)
        Spacer()
        Button("Done") { dismiss() }
      }.padding()
      Divider()
      if store.running.isEmpty {
        Text("No sandboxed apps running.").foregroundStyle(.secondary)
          .frame(maxWidth: .infinity).padding(.vertical, 22)
      } else {
        Table(store.runningSessions()) {
          TableColumn("App") { Text($0.name) }
          TableColumn("Policy") { Text($0.policy) }
          TableColumn("CPU") { Text(String(format: "%.0f%%", $0.m.cpu)).monospacedDigit() }
          TableColumn("Memory") { Text(String(format: "%.0f MB", $0.m.memMB)).monospacedDigit() }
          TableColumn("Disk I/O") { Text(String(format: "%.0f MB", $0.m.diskMB)).monospacedDigit() }
          TableColumn("Procs") { Text("\($0.m.procs)").monospacedDigit() }
        }.frame(minHeight: 120)
      }
      Divider()
      VStack(alignment: .leading, spacing: 6) {
        Text("On-disk footprint").font(.subheadline).bold()
        HStack(spacing: 18) {
          footprint("active stashes", report.activeSessions, safe: false)
          footprint("commit archives", report.archives, safe: false)
          footprint("temp homes", report.tempHomes, safe: true)
          footprint("VM clones", report.vmClones.count, safe: true)
          Spacer()
          Button("Clean orphans") { Traces.purgeOrphans(); report = Traces.scan() }
            .disabled(report.orphans == 0)
        }
        Text("Active stashes + archives are protected (they hold your real data). macOS's unified log still records native app launches — no unprivileged tool can suppress that; only the Paranoid VM keeps launches off the host log entirely.")
          .font(.caption2).foregroundStyle(.secondary)
      }.padding(12)
    }
    .frame(width: 660, height: 440)
    .onAppear { report = Traces.scan() }
  }

  private func footprint(_ label: String, _ n: Int, safe: Bool) -> some View {
    VStack(spacing: 2) {
      Text("\(n)").font(.title3).monospacedDigit()
        .foregroundStyle(n > 0 && safe ? .orange : .primary)
      Text(label).font(.caption2).foregroundStyle(.secondary)
    }
  }
}
