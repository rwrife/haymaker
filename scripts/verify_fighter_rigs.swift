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
   boxer.pose(FighterStatus(state: .blocking), time: 0, recoil: 0, reducedMotion: true)
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
   boxer.pose(FighterStatus(state: .blocking), time: 0, recoil: 0, reducedMotion: true)
   print("Verified \(asset.rawValue): 16 bones, 216 pose combinations, bounded head rotation")
  }
  let camera = SCNNode(); camera.camera = SCNCamera();camera.camera!.usesOrthographicProjection = true;camera.camera!.orthographicScale = 5.1
  camera.position = SCNVector3(2.7, -1.9, 12); scene.rootNode.addChildNode(camera)
  let light = SCNNode();light.light = SCNLight();light.light!.type = .ambient;light.light!.intensity = 450;scene.rootNode.addChildNode(light)
  let key = SCNNode();key.light = SCNLight();key.light!.type = .omni;key.light!.intensity = 550;key.position = SCNVector3(-2,6,8);scene.rootNode.addChildNode(key)
  let renderer = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil);renderer.scene = scene;renderer.pointOfView = camera
  SCNTransaction.commit(); SCNTransaction.flush()
  _ = renderer.snapshot(atTime: 0, with: CGSize(width: 16, height: 16), antialiasingMode: .none)
  let image = renderer.snapshot(atTime: 1, with: CGSize(width: 1500, height: 1600), antialiasingMode: .multisampling4X)
  let png = NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
  try png.write(to: URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/haymaker-rig-guard.png"))
 }
}
