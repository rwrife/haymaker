import SwiftUI
import HaymakerKit
import HaymakerStore

/// Skeleton root view. The M3 fight scene (issue #3) replaces this with the
/// SpriteKit match view routed through `FightWorkspaceLayout` (issue #5),
/// the single seam where a future dual-screen split would attach.
struct ContentView: View {
    var body: some View {
        VStack(spacing: 8) {
            Text("Haymaker")
                .font(.title)
                .accessibilityAddTraits(.isHeader)
            Text(HaymakerKit.milestone)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text(HaymakerStore.milestone)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding()
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    ContentView()
}
