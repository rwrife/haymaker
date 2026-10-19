import SwiftUI

/// All bundled fighter portraits are 1024 x 1536; only their top 30% fills the panel.
struct FighterPortrait: View {
    let assetName: String

    var body: some View {
        GeometryReader { geometry in
            let scale = max(geometry.size.width / 1024, geometry.size.height / (1536 * 0.30))
            let imageHeight = 1536 * scale
            Image(assetName)
                .resizable()
                .frame(width: 1024 * scale, height: imageHeight)
                .position(x: geometry.size.width / 2, y: imageHeight / 2)
        }
        .clipped()
    }
}
