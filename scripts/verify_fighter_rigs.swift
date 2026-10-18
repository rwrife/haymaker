import AppKit
import SceneKit
import HaymakerKit
typealias UIColor = NSColor
@main struct Verify {
 @MainActor static func main() throws {
  SCNTransaction.begin(); SCNTransaction.disableActions = true
  let scene = SCNScene()
  scene.background.contents = NSColor.darkGray
  for (i, asset) in FighterModelAsset.allCases.enumerated() {
   let boxer = BoxerModel(asset: asset, isRival: false)
   boxer.pose(FighterStatus(state: .blocking, ticksInCurrentState: 8, stateDuration: 24), time: 0, recoil: 0, reducedMotion: true)
   boxer.root.position = SCNVector3(Float(i % 3) * 2.7, -Float(i / 3) * 3.2, 0)
   scene.rootNode.addChildNode(boxer.root)
   let mesh = boxer.root.childNode(withName: "skinnedMesh", recursively: true)!
   let skinner = mesh.skinner!
   precondition(skinner.bones.count == 16)
   let head = boxer.root.childNode(withName: "head", recursively: true)!
   let leftHand = boxer.root.childNode(withName: "leftHand", recursively: true)!
   let bindHead = head.simdPosition
   let guardHand = leftHand.simdWorldPosition
   // Exercise every lifecycle state, attack type, progress extreme and motion setting.
   for state in [FighterState.idle, .telling, .attacking, .recovering, .blocking, .parrying, .dodging, .knockedDown, .ko] {
    for move in [Move.jab, .hook, .uppercut, .feint] {
     for tick in [0, 15, 30] {
      for reduced in [false, true] {
       boxer.pose(FighterStatus(state: state, ticksInCurrentState: tick, stateDuration: 30, currentMove: move), time: 1.7, recoil: 0.35, reducedMotion: reduced)
       precondition(abs(head.simdEulerAngles.y) <= BoxerModel.maximumHeadYaw)
       precondition(simd_distance(head.simdPosition, bindHead) < 0.00001)
       for bone in skinner.bones {
        precondition(bone.simdTransform.columns.0.x.isFinite)
        precondition(abs(simd_length(bone.simdOrientation.vector) - 1) < 0.0001)
       }
      }
     }
    }
   }
   boxer.pose(FighterStatus(state: .attacking, ticksInCurrentState: 30, stateDuration: 30, currentMove: .jab), time: 0, recoil: 0, reducedMotion: true)
   precondition(simd_distance(leftHand.simdWorldPosition, guardHand) > 0.1, "Punch must move the glove")
   // Real transitions clear currentMove on recovery. The presentation must
   // retain the striking hand and retract from contact instead of teleporting.
   for move in [Move.jab, .hook, .uppercut] {
    for told in [false, true] {
     boxer.resetMotion()
     if told {
      boxer.pose(FighterStatus(state: .telling, ticksInCurrentState: 30, stateDuration: 30, currentMove: move), time: 0, recoil: 0, reducedMotion: true)
      let loaded = skinner.bones.map { $0.simdWorldPosition }
      boxer.pose(FighterStatus(state: .attacking, stateDuration: 30, currentMove: move), time: 0, recoil: 0, reducedMotion: true)
      for (bone, position) in zip(skinner.bones, loaded) {
       precondition(simd_distance(bone.simdWorldPosition, position) < 0.0001, "Tell/strike discontinuity")
      }
     }
     let hand = skinner.bones[move == .hook ? 9 : 6]
     boxer.pose(FighterStatus(state: .attacking, ticksInCurrentState: 30, stateDuration: 30, currentMove: move), time: 0, recoil: 0, reducedMotion: true)
     let contact = hand.simdWorldPosition
     let contactRotation = hand.simdWorldOrientation
     boxer.pose(FighterStatus(state: .recovering, stateDuration: 20), time: 0, recoil: 0, reducedMotion: true)
     precondition(simd_distance(hand.simdWorldPosition, contact) < 0.0001, "Glove snapped back at impact")
     precondition(abs(simd_dot(hand.simdWorldOrientation.vector, contactRotation.vector)) > 0.9999)
     boxer.pose(FighterStatus(state: .recovering, ticksInCurrentState: 20, stateDuration: 20), time: 0, recoil: 0, reducedMotion: true)
     let returned = hand.simdWorldPosition
     boxer.pose(FighterStatus(), time: 0, recoil: 0, reducedMotion: true)
     precondition(simd_distance(hand.simdWorldPosition, returned) < 0.0001, "Recovery/guard discontinuity")
    }
   }
   boxer.resetMotion()
   boxer.pose(FighterStatus(), time: 0, recoil: 0, reducedMotion: false)
   let chest = skinner.bones[1].simdScale
   let foot = skinner.bones[12].simdWorldPosition
   precondition(abs(skinner.bones[11].simdEulerAngles.x) > 0.1, "Knees must bend in stance")
   precondition(abs(skinner.bones[6].simdOrientation.real) < 0.001, "Guard wrist must correct glove roll")
   boxer.pose(FighterStatus(), time: 0.3, recoil: 0, reducedMotion: false)
   precondition(simd_distance(skinner.bones[1].simdScale, chest) > 0.001, "Chest must breathe")
   precondition(simd_distance(skinner.bones[12].simdWorldPosition, foot) > 0.01, "Feet must shuffle")
   boxer.pose(FighterStatus(), time: 0.3, recoil: 0, reducedMotion: true)
   let still = skinner.bones.map { $0.simdTransform }
   boxer.pose(FighterStatus(), time: 3, recoil: 0, reducedMotion: true)
   for (bone, transform) in zip(skinner.bones, still) {
    for column in 0..<4 { precondition(simd_distance(bone.simdTransform[column], transform[column]) < 0.0001, "Reduced motion must suppress idle movement") }
   }
   boxer.poseWarmup(time: 0, reducedMotion: false)
   let warmupStartHand = leftHand.simdWorldPosition
   for sample in stride(from: Float(0), through: 6.4, by: 0.25) {
    boxer.poseWarmup(time: sample, reducedMotion: false)
    precondition(abs(head.simdEulerAngles.y) <= BoxerModel.maximumHeadYaw)
    precondition(simd_distance(head.simdPosition, bindHead) < 0.00001)
    let hips = skinner.bones[0].simdPosition
    precondition(hypot(hips.x, hips.z) < 0.06, "Warmup pelvis must stay stationary over the stance")
    for bone in skinner.bones {
     precondition(bone.simdTransform.columns.0.x.isFinite)
     precondition(abs(simd_length(bone.simdOrientation.vector) - 1) < 0.0001)
    }
   }
   boxer.poseWarmup(time: 0.85, reducedMotion: false)
   precondition(simd_distance(leftHand.simdWorldPosition, warmupStartHand) > 0.1, "Warmup must animate the arms")
   boxer.poseWarmup(time: 0.4, reducedMotion: true)
   let warmupStill = skinner.bones.map { $0.simdTransform }
   boxer.poseWarmup(time: 4.2, reducedMotion: true)
   for (bone, transform) in zip(skinner.bones, warmupStill) {
    for column in 0..<4 { precondition(simd_distance(bone.simdTransform[column], transform[column]) < 0.0001, "Reduced motion must suppress warmup movement") }
   }
   boxer.pose(FighterStatus(state: .blocking, ticksInCurrentState: 8, stateDuration: 24), time: 0, recoil: 0, reducedMotion: true)
   print("Verified \(asset.rawValue): 16 bones, 216 pose combinations, bounded head rotation")
  }
  // Frame every roster row, including the tenth model on the fourth row.
  let rows = (FighterModelAsset.allCases.count + 2) / 3
  let camera = SCNNode(); camera.camera = SCNCamera();camera.camera!.usesOrthographicProjection = true;camera.camera!.orthographicScale = Double(rows) * 1.6 + 0.3
  camera.position = SCNVector3(2.7, 1.35 - Float(rows - 1) * 1.6, 12); scene.rootNode.addChildNode(camera)
  let light = SCNNode();light.light = SCNLight();light.light!.type = .ambient;light.light!.intensity = 450;scene.rootNode.addChildNode(light)
  let key = SCNNode();key.light = SCNLight();key.light!.type = .omni;key.light!.intensity = 550;key.position = SCNVector3(-2,6,8);scene.rootNode.addChildNode(key)
  let renderer = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil);renderer.scene = scene;renderer.pointOfView = camera
  SCNTransaction.commit(); SCNTransaction.flush()
  _ = renderer.snapshot(atTime: 0, with: CGSize(width: 16, height: 16), antialiasingMode: .none)
  let image = renderer.snapshot(atTime: 1, with: CGSize(width: 1500, height: rows * 550), antialiasingMode: .multisampling4X)
  let png = NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
  try png.write(to: URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/haymaker-rig-guard.png"))
  // A second image makes the full-body strike arc reviewable side by side.
  let motionScene = SCNScene()
  motionScene.background.contents = NSColor.darkGray
  for row in 0..<2 {
   for frame in 0..<5 {
    let boxer = BoxerModel(asset: row == 0 ? .mack : .bruiser, isRival: false)
    boxer.pose(FighterStatus(state: .telling, ticksInCurrentState: 30, stateDuration: 30, currentMove: .jab), time: 0, recoil: 0, reducedMotion: false)
    if frame == 0 { boxer.resetMotion(); boxer.pose(FighterStatus(), time: 0, recoil: 0, reducedMotion: false) }
    if frame >= 2 { boxer.pose(FighterStatus(state: .attacking, ticksInCurrentState: 30, stateDuration: 30, currentMove: .jab), time: 0.3, recoil: 0, reducedMotion: false) }
    if frame >= 3 { boxer.pose(FighterStatus(state: .recovering, ticksInCurrentState: frame == 3 ? 10 : 20, stateDuration: 20), time: 0.5, recoil: 0, reducedMotion: false) }
    boxer.root.eulerAngles.y = -.pi / 5
    boxer.root.position = SCNVector3(Float(frame) * 2.3, -Float(row) * 3.1, 0)
    motionScene.rootNode.addChildNode(boxer.root)
   }
  }
  camera.position = SCNVector3(4.6, -0.1, 14)
  camera.camera!.orthographicScale = 3.4
  motionScene.rootNode.addChildNode(camera); motionScene.rootNode.addChildNode(light); motionScene.rootNode.addChildNode(key)
  renderer.scene = motionScene
  SCNTransaction.flush()
  let motion = renderer.snapshot(atTime: 2, with: CGSize(width: 1900, height: 1050), antialiasingMode: .multisampling4X)
  let motionPNG = NSBitmapImageRep(data: motion.tiffRepresentation!)!.representation(using: .png, properties: [:])!
  let motionURL = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/haymaker-rig-guard.png").deletingPathExtension().appendingPathExtension("motion.png")
  try motionPNG.write(to: motionURL)

 }
}
