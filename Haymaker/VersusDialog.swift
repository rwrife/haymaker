import SwiftUI
import HaymakerKit

/// The bout is frozen behind this modal until the player rings the bell.
struct VersusDialog: View {
    let book: OpponentBook
    let portrait: Bool
    let fight: () -> Void
    let cancel: () -> Void

    private let gold = Color(red: 0.98, green: 0.72, blue: 0.25)
    private let ink = Color(red: 0.025, green: 0.04, blue: 0.075)

    var body: some View {
        ZStack {
            ink.opacity(0.98).ignoresSafeArea()
            GeometryReader { geometry in
                ScrollView {
                    VStack(spacing: portrait ? 18 : 10) {
                        HStack {
                            Text("THE CHALLENGER APPROACHES")
                                .font(.system(size: 10, weight: .black)).tracking(2)
                                .foregroundStyle(gold)
                            Spacer()
                            Button(action: cancel) {
                                Image(systemName: "xmark").frame(width: 44, height: 44)
                            }
                            .accessibilityLabel("Return without starting bout")
                            .accessibilityIdentifier("versus.cancel")
                        }
                        if portrait {
                            face(height: min(geometry.size.height * 0.38, 310))
                            introduction
                        } else {
                            HStack(spacing: 24) {
                                face(height: max(160, geometry.size.height - 130))
                                    .frame(maxWidth: geometry.size.width * 0.43)
                                introduction
                            }
                        }
                        Button(action: fight) {
                            HStack {
                                Text("RING THE BELL")
                                Image(systemName: "arrow.right")
                            }
                            .font(.system(size: 19, weight: .black, design: .rounded))
                            .frame(maxWidth: .infinity, minHeight: 54)
                            .foregroundStyle(ink)
                            .background(gold, in: RoundedRectangle(cornerRadius: 8))
                        }
                        .accessibilityIdentifier("versus.fight")
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 8)
                    .frame(maxWidth: 850)
                    .frame(maxWidth: .infinity, minHeight: geometry.size.height)
                }
            }
        }
        .foregroundStyle(.white)
        .accessibilityAddTraits(.isModal)
        .accessibilityIdentifier("versus.dialog")
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("VS")
                .font(.custom("AvenirNextCondensed-Heavy", size: 42)).italic().foregroundStyle(gold)
            Text(book.name.uppercased())
                .font(.custom("AvenirNextCondensed-Heavy", size: portrait ? 34 : 30))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("versus.opponent")
            Text(book.character?.style ?? "CHALLENGER")
                .font(.system(size: 10, weight: .heavy)).tracking(1.5).foregroundStyle(gold)
            Text("“\(book.character?.taunt ?? "Meet me in the ring.")”")
                .font(.system(size: portrait ? 19 : 17, weight: .semibold, design: .rounded))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("versus.taunt")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func face(height: CGFloat) -> some View {
        GeometryReader { geometry in
            // The source PNGs are 1024 × 1536. Fill the panel using only
            // their top 30%, keeping the crop pinned to the top edge.
            let scale = max(geometry.size.width / 1024, geometry.size.height / (1536 * 0.30))
            let imageWidth = 1024 * scale
            let imageHeight = 1536 * scale
            Image("\(book.character?.asset ?? "bruiser")-intro")
                .resizable()
                .frame(width: imageWidth, height: imageHeight)
                .position(x: geometry.size.width / 2, y: imageHeight / 2)
        }
        .frame(height: height)
        .background(LinearGradient(colors: [gold.opacity(0.18), ink], startPoint: .topLeading, endPoint: .bottomTrailing))
        .clipped()
        .overlay(alignment: .bottom) {
            LinearGradient(colors: [.clear, ink], startPoint: .top, endPoint: .bottom)
                .frame(height: 55)
        }
        .overlay(Rectangle().stroke(gold.opacity(0.55), lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isImage)
        .accessibilityLabel("Close-up portrait of \(book.name)")
        .accessibilityIdentifier("versus.portrait.\(book.id)")
    }
}
