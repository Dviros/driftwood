import SwiftUI

struct ContentView: View {
  @EnvironmentObject var store: Store
  private let cols = [GridItem(.adaptive(minimum: 142), spacing: 16)]

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider().opacity(0.3)
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
                  AppCard(app: app, running: store.isRunning(app), metrics: store.metrics[app.id]) {
                    store.toggle(app)
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
  }

  private var header: some View {
    HStack(spacing: 12) {
      Image(systemName: "wind").foregroundStyle(.teal)
      Text("driftwood").font(.headline)
      Text("\(store.running.count) live").font(.caption).foregroundStyle(.secondary)
      Spacer()
      Picker("", selection: $store.policy) {
        ForEach(Policy.allCases) { Text($0.rawValue).tag($0) }
      }
      .pickerStyle(.segmented).frame(width: 240).help(store.policy.blurb)
      Toggle("Ask on close", isOn: $store.askOnClose).toggleStyle(.checkbox).controlSize(.small)
      TextField("Search", text: $store.query).textFieldStyle(.roundedBorder).frame(width: 150)
      Button { store.rescan() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless)
    }
    .padding(.horizontal, 20).padding(.vertical, 12)
    .background(.ultraThinMaterial)
  }
}

struct AppCard: View {
  let app: InstalledApp
  let running: Bool
  let metrics: Metrics?
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
