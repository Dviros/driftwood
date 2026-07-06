import SwiftUI

struct ContentView: View {
  @EnvironmentObject var store: Store
  private let columns = [GridItem(.adaptive(minimum: 136), spacing: 16)]

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider().opacity(0.4)
      ScrollView {
        LazyVGrid(columns: columns, spacing: 16) {
          ForEach(store.filtered) { app in
            AppCard(app: app, running: store.isRunning(app)) { store.toggle(app) }
          }
        }
        .padding(20)
      }
    }
    .background(VisualEffect().ignoresSafeArea())
  }

  private var header: some View {
    HStack(spacing: 12) {
      Image(systemName: "wind").font(.title3).foregroundStyle(.teal)
      Text("driftwood").font(.headline)
      Text("\(store.runningAppIDs.count) sandboxed")
        .font(.caption).foregroundStyle(.secondary)
      Spacer()
      Toggle("No network", isOn: $store.noNet)
        .toggleStyle(.switch).controlSize(.mini)
      TextField("Search apps", text: $store.query)
        .textFieldStyle(.roundedBorder).frame(width: 190)
      Button { store.rescan() } label: { Image(systemName: "arrow.clockwise") }
        .buttonStyle(.borderless).help("Rescan installed apps")
    }
    .padding(.horizontal, 20).padding(.vertical, 14)
    .background(.ultraThinMaterial)
  }
}

struct AppCard: View {
  let app: InstalledApp
  let running: Bool
  let action: () -> Void
  @State private var hover = false

  var body: some View {
    Button(action: action) {
      VStack(spacing: 10) {
        ZStack(alignment: .topTrailing) {
          Image(nsImage: app.icon).resizable()
            .frame(width: 56, height: 56)
          if running {
            Circle().fill(.green).frame(width: 11, height: 11)
              .overlay(Circle().strokeBorder(.white.opacity(0.8), lineWidth: 1))
              .offset(x: 4, y: -4)
          }
        }
        Text(app.name).font(.callout).lineLimit(1).foregroundStyle(.primary)
        Text(running ? "running · click to close" : "click to launch")
          .font(.caption2)
          .foregroundStyle(running ? Color.green : .secondary)
      }
      .frame(maxWidth: .infinity)
      .padding(.vertical, 18).padding(.horizontal, 8)
      .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
      .overlay(
        RoundedRectangle(cornerRadius: 16)
          .strokeBorder(running ? Color.green.opacity(0.7) : Color.white.opacity(0.12),
                        lineWidth: 1)
      )
      .shadow(color: .black.opacity(hover ? 0.28 : 0.12),
              radius: hover ? 11 : 5, y: 3)
      .scaleEffect(hover ? 1.03 : 1.0)
    }
    .buttonStyle(.plain)
    .onHover { hover = $0 }
    .animation(.easeOut(duration: 0.15), value: hover)
    .animation(.easeOut(duration: 0.20), value: running)
    .help(app.path)
  }
}
