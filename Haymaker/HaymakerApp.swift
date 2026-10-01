import SwiftUI
import HaymakerKit
import HaymakerStore

/// Haymaker app entry point.
///
/// iPhone-only by product contract (`TARGETED_DEVICE_FAMILY = 1` in every
/// build configuration; CI enforces it pre- and post-build). Zero-network by
/// construction: no network APIs anywhere in app or package sources — CI
/// enforces an empty-allowlist scan per `toolchain.json`.
@main
struct HaymakerApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
