import SwiftUI
import SceneKit
import Metal

/// Forces the native 3D renderer onto Metal, with HDR and multisample antialiasing.
struct MetalArenaView: UIViewRepresentable {
    let arena: MatchScene
    let portrait: Bool
    let paused: Bool

    final class Coordinator { var portrait: Bool? }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView(frame: .zero, options: [SCNView.Option.preferredRenderingAPI.rawValue: SCNRenderingAPI.metal.rawValue])
        assert(view.renderingAPI == .metal, "The arena requires the Metal renderer")
        view.scene = arena.scene
        view.pointOfView = arena.camera
        view.antialiasingMode = .multisampling4X
        view.preferredFramesPerSecond = 60
        view.isPlaying = true
        view.rendersContinuously = true
        view.autoenablesDefaultLighting = false
        view.backgroundColor = .black
        view.isUserInteractionEnabled = false
        arena.layout(portrait: portrait)
        context.coordinator.portrait = portrait
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        if view.scene !== arena.scene {
            view.scene = arena.scene
            view.pointOfView = arena.camera
            arena.layout(portrait: portrait)
        }
        if context.coordinator.portrait != portrait {
            arena.layout(portrait: portrait)
            context.coordinator.portrait = portrait
        }
        view.isPlaying = !paused
        view.rendersContinuously = !paused
    }
}
