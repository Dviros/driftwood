import SwiftUI
import AppKit

/// Window-vibrancy backdrop for the Liquid-Glass look.
struct VisualEffect: NSViewRepresentable {
  func makeNSView(context: Context) -> NSVisualEffectView {
    let v = NSVisualEffectView()
    v.material = .underWindowBackground
    v.blendingMode = .behindWindow
    v.state = .active
    return v
  }
  func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
