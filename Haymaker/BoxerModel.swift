import SceneKit
import HaymakerKit

/// All supplied sculpts share the same named, 16-bone T-pose skeleton.
enum FighterModelAsset: String, CaseIterable {
    case mack, bruiser, goldie, nico, atlas, duke, sylvie, cassian, vera, jaison
}

@MainActor final class BoxerModel {
    let root = SCNNode()
    private let bones: [SCNNode]
    private let bindPositions: [SIMD3<Float>]
    private let isRival: Bool
    static let maximumHeadYaw: Float = .pi / 60 // Three degrees, including hit reactions.

    convenience init(isRival: Bool) {
        self.init(asset: isRival ? .bruiser : .mack, isRival: isRival)
    }

    init(asset: FighterModelAsset, isRival: Bool) {
        self.isRival = isRival
        let rig = FighterRig.load(asset)
        bones = rig.bones
        bindPositions = rig.positions
        root.name = asset.rawValue
        root.addChildNode(rig.skeleton)
        root.addChildNode(rig.mesh)
        root.scale = isRival ? SCNVector3(1.13, 1.13, 1.13) : SCNVector3(0.96, 0.96, 0.96)
    }

    private var previousState: FighterState = .idle
    private var punchMove: Move = .idle
    private var hasWindup = false
    private(set) var forwardDrive: Float = 0
    private(set) var slip: Float = 0

    func resetMotion() {
        previousState = .idle
        punchMove = .idle
        hasWindup = false
        forwardDrive = 0
        slip = 0
    }

    private func ease(_ value: Float) -> Float {
        let t = min(1, max(0, value))
        return t * t * (3 - 2 * t)
    }

    func pose(_ status: FighterStatus, time: Float, recoil: Float, reducedMotion: Bool) {
        for bone in bones {
            bone.simdOrientation = simd_quatf(angle: 0, axis: [0, 1, 0])
            bone.simdScale = SIMD3<Float>(repeating: 1)
        }
        bones[0].simdPosition = bindPositions[0]
        root.simdEulerAngles.z = 0
        let progress = min(1, max(0, Float(status.ticksInCurrentState) / Float(max(1, status.stateDuration))))
        let down = status.state == .knockedDown || status.state == .ko
        let rhythm: Float = reducedMotion || down ? 0 : 1
        // A slower respiratory cycle gently expands the chest and raises the
        // shoulders independently of the quicker boxing weight shift.
        let breath = (sin(time * 2.1) + 1) * 0.5 * rhythm
        bones[1].simdScale = SIMD3<Float>(1 + breath * 0.008, 1 + breath * 0.005, 1 + breath * 0.012)
        let beat = time * 4.6
        let sway = sin(beat) * rhythm
        let bounce = (1 - cos(beat * 2)) * 0.012 * rhythm
        var targets = [SIMD3<Float>(-0.17, 0.75, 0.15), SIMD3<Float>(0.17, 0.75, 0.13)]
        let guardTargets = targets
        var reachAmount: Float = 0
        var chamber: Float = 0
        var twist: Float = 0
        forwardDrive = 0
        slip = 0

        if status.state == .telling || status.state == .attacking {
            if status.state != previousState {
                hasWindup = status.state == .telling || previousState == .telling
            }
            punchMove = status.currentMove
        } else if status.state != .recovering || (previousState != .attacking && previousState != .telling && previousState != .recovering) {
            punchMove = .idle
        }
        let offensive = punchMove == .jab || punchMove == .hook || punchMove == .uppercut || punchMove == .feint
        if offensive {
            switch status.state {
            case .telling:
                chamber = ease(progress)
            case .attacking:
                // The player's windup is inside attacking; opponents already
                // chambered during their authored, readable tell window.
                chamber = hasWindup ? 1 : ease(progress / 0.22)
                reachAmount = ease((progress - (hasWindup ? 0 : 0.22)) / (hasWindup ? 1 : 0.78))
            case .recovering:
                reachAmount = punchMove == .feint ? 0 : 1 - ease(progress)
                chamber = punchMove == .feint ? 1 - ease(progress) : reachAmount
            default: break
            }
            let arm = punchMove == .hook ? 1 : 0
            let sign: Float = arm == 0 ? -1 : 1
            var loaded = guardTargets[arm]
            loaded.x += sign * 0.045
            loaded.z -= 0.055
            if punchMove == .uppercut { loaded.y -= 0.11 }
            let start = simd_mix(guardTargets[arm], loaded, SIMD3<Float>(repeating: chamber))
            let contact: SIMD3<Float>
            switch punchMove {
            case .hook: contact = SIMD3<Float>(-0.08, 0.79, 0.32)
            case .uppercut: contact = SIMD3<Float>(-0.10, 0.83, 0.32)
            default: contact = SIMD3<Float>(-0.10, 0.77, 0.39)
            }
            targets[arm] = simd_mix(start, contact, SIMD3<Float>(repeating: reachAmount))
            // A hook travels around the guard rather than along a straight jab.
            if punchMove == .hook { targets[arm].x += sin(reachAmount * .pi) * 0.12 }
            twist = sign * (0.10 * chamber * (1 - reachAmount) - 0.18 * reachAmount)
            forwardDrive = reachAmount
        }
        switch status.state {
        case .blocking, .parrying:
            let raised = ease(Float(status.ticksInCurrentState) / 4)
            for side in 0..<2 {
                let high = SIMD3<Float>(side == 0 ? -0.105 : 0.105, 0.80, 0.15)
                targets[side] = simd_mix(targets[side], high, SIMD3<Float>(repeating: raised))
            }
        case .dodging:
            slip = sin(progress * .pi)
        case .knockedDown, .ko:
            root.simdEulerAngles.z = reducedMotion ? 0.2 : 1.05
        default: break
        }
        bones[0].simdPosition += SIMD3<Float>(sway * 0.026 - slip * 0.12, -0.085 - bounce - slip * 0.12, 0)
        bones[0].simdEulerAngles.y = twist * 0.35
        bones[1].simdEulerAngles = SIMD3<Float>(-min(max(recoil, 0), 0.3) + reachAmount * 0.035,
                                               twist + sway * 0.025, sway * 0.025 + slip * 0.16)
        // The jaw stays rigid with the skull, with only a bounded head yaw.
        bones[3].simdEulerAngles.y = isRival ? -0.025 : 0.025
        for side in 0..<2 {
            targets[side].y += sway * (side == 0 ? 0.004 : -0.004)
            poseArm(side, target: targets[side] * 2.7, reachAmount: reachAmount, punching: offensive && side == (punchMove == .hook ? 1 : 0))
            let phase = beat + (side == 0 ? 0 : Float.pi)
            // Alternating short shuffles: lift only the advancing foot. The
            // support leg is solved against the mat, not dragged by hip bob.
            let lift = pow(max(0, sin(phase)), 2) * 0.045 * rhythm
            let foot = bindPositions[12 + side * 3] + SIMD3<Float>(side == 0 ? -0.045 : 0.045,
                lift, (side == 0 ? 0.14 : -0.14) + cos(phase) * 0.045 * rhythm + reachAmount * 0.035)
            poseLeg(side, target: foot)
        }
        previousState = status.state
    }

    /// Solve in hip-local space so the feet counteract pelvis weight shifts.
    private func poseLeg(_ side: Int, target: SIMD3<Float>) {
        let hip = 10 + side * 3
        let knee = hip + 1
        let foot = hip + 2
        let targetInHips = bones[0].simdOrientation.inverse.act(target - bones[0].simdPosition)
        let origin = bindPositions[hip] - bindPositions[0]
        let upperAxis = bindPositions[knee] - bindPositions[hip]
        let lowerAxis = bindPositions[foot] - bindPositions[knee]
        let delta = targetInHips - origin
        let direction = simd_normalize(delta)
        let upper = simd_length(upperAxis), lower = simd_length(lowerAxis)
        let reach = min(upper + lower - 0.001, max(abs(upper - lower) + 0.001, simd_length(delta)))
        let along = (upper * upper - lower * lower + reach * reach) / (2 * reach)
        let pole = SIMD3<Float>(0, 0, 1)
        let bend = simd_normalize(pole - direction * simd_dot(pole, direction))
        let joint = direction * along + bend * sqrt(max(0, upper * upper - along * along))
        let upperRotation = simd_quatf(from: simd_normalize(upperAxis), to: simd_normalize(joint))
        let lowerRotation = simd_quatf(from: simd_normalize(lowerAxis), to: simd_normalize(direction * reach - joint))
        bones[hip].simdOrientation = upperRotation
        bones[knee].simdOrientation = upperRotation.inverse * lowerRotation
        bones[foot].simdOrientation = (bones[0].simdOrientation * lowerRotation).inverse
    }

    /// Two-bone IK preserves upper/lower arm lengths and keeps elbows away from
    /// the ribcage. Targets are in the spine's undeformed coordinate system.
    private func poseArm(_ side: Int, target: SIMD3<Float>, reachAmount: Float, punching: Bool) {
        let shoulder = 4 + side * 3
        let elbow = shoulder + 1
        let hand = shoulder + 2
        let origin = bindPositions[shoulder]
        let upper = simd_distance(origin, bindPositions[elbow])
        let lower = simd_distance(bindPositions[elbow], bindPositions[hand])
        let delta = target - origin
        let direction = simd_normalize(delta)
        let reach = min(upper + lower - 0.001, max(abs(upper - lower) + 0.001, simd_length(delta)))
        let along = (upper * upper - lower * lower + reach * reach) / (2 * reach)
        let pole = SIMD3<Float>(side == 0 ? -0.5 : 0.5, -1, 0)
        let bend = simd_normalize(pole - direction * simd_dot(pole, direction))
        let joint = origin + direction * along + bend * sqrt(max(0, upper * upper - along * along))
        let end = origin + direction * reach
        let restAxis = SIMD3<Float>(side == 0 ? -1 : 1, 0, 0)
        let upperRotation = simd_quatf(from: restAxis, to: simd_normalize(joint - origin))
        let lowerRotation = simd_quatf(from: restAxis, to: simd_normalize(end - joint))
        bones[shoulder].simdOrientation = upperRotation
        bones[elbow].simdOrientation = upperRotation.inverse * lowerRotation
        // T-pose glove thumbs point down when the forearm is simply aimed at
        // the guard. Roll each wrist half a turn around its outward bind axis
        // so thumbs sit inward/up; gradually turn the fist over on a punch.
        let roll = simd_quatf(angle: .pi + (punching ? reachAmount * .pi / 3 : 0), axis: restAxis)
        bones[hand].simdOrientation = roll
    }

    private struct WarmupFrame {
        let hips: SIMD3<Float>
        let orientations: [simd_quatf]
    }

    /// Retargeted 152-frame (24 fps) shadowboxing warm-up loop (arm swings, step-in,
    /// jab/cross/hook combinations, weave, and return to center guard).
    private static let warmupFrames: [WarmupFrame] = {
        let encoded =
            "zVdZcx1HFe6emZ79zl20W1EUSbaVYJkKdkKFYMDlVH4BD7wAP443eOEZiqQKg4qEwk4qxJDIVrwIW7KWu80+0wvndF/ZQFUeeHNr7lXfXs/5" +
            "zjnfOaMUoRallMCjG/RhQHeVxD+pFPT1EH6UovCRUgopcSH0lN5mQbNxhOIiReCPwjbbgiElheAt1ytxseUwx7bMQbMxWCP15eYSsku9uBu5" +
            "lmrzNG2dqBO5pC3SaSndThJ7VJTZNONO3O0EtmyyaVqToBMHjmqLohI2YzYKqc+SvIW7CXV833UISNw2dSvO7/22Rp0wDhltq7KhIUpCVJNP" +
            "0jogSkgBMFAbdEBRQUtqNOCcCwUwWKixhAUMujgjhFBqpqaQCrFCwHCf1lgiYgg4mQ3jb2MHyZuqFf8jG8KKR8AefKhlGwPhWUpbDA1CZ329" +
            "SGEfT6X6Ag3zua3IORh6HD2AzKSh5lgb9BBtAzBqjwBcLcdxXc9ljjGkFKi7nMmjryHmaqVSRbW7AKSe79pKcECDwnYbbIF+AXOybZumQauA" +
            "aqoGe2ZpXsJMNTqd1JIGi5uXN1cvLM+51dnTR/tPTiqLEWnHc/NziW+1+WQMzuDHSZKEnu97lFdFpltewm5wN8dhzPVRYNfTYsPHMsqTmftr" +
            "vYiBHbsaJRxHjbA7s4vpGlc1qEoNrdIBYyCExzZ32pTCRAtqwqMASbgZvN/s1WYRQhr7GweBmUUAhoP/2FoEwEjgaQC0jpeZXNTcDaBD3CnR" +
            "CurgekvrokSZF8J2/cADPS0QoK5q2EzdyGdUgU/VXPFyfPL8LJfh4ualtYVetxMFjOLKsoLVjTEMuq5xFrgzRme3ZkGFF9sY8uDeKKYiegZR" +
            "ggi3AF3Bpc0c5gUerdJceKFV5TX4gZv0OxYoZSkIzabM8wb186I49hwCHoHBQm3mOqKuGrwGF3LNFRhdFF1I4ihcgLJgMGMMaMsJWIlzgA6A" +
            "omxXByFIbVDWOCNa4L2OA9DhTbYC64i2LMq6LooC9IczHBemLVE3yu0ub25vb13os2Z6/PTx/jdPDo9HWev0lta3ttbmYwe2oybw1GXdKhPQ" +
            "YBulxmoWsZb1guektrIhDWrCxcQnfgN0jkMNJeumpGZo7TDEEC8xsY3ci+vB/Pjf0mSDuDFmYchBnHFcLvDLULkis7PomTJyEROw9JwElKER" +
            "42Hk3M+NS2t8kQx0g3GJkFXg1+juLoQUzNkUmAKggBBnGGSUavqT2kpoOTiBMRRxdjmCJTVVadRsc9kMt3NSOicUZajRjL0gLqVMJKGLGPJD" +
            "zLSMmmSlxkr7q01UW9fgP+Y2JE+GRAYeI1FMI4fmAZMYyex5ddtoln3aOh8++uxPf77zDyDITEXLWzvvvP+jH767s7EYUyHKk/t/+/h3v9/9" +
            "8pl47dYvf37z8sp8h0nILcwS2XBckLjrTA8eHrduFIXM762sdEk2KSXV+Utjiz2JoQbh7QFbGBprqyKvOAW6A08k6qXpfjb7weuiVH6vFzNI" +
            "iS74CGzJ0tOnj54cHByVyetbayuL3SiaW1nuOdnx82FaSDcEzsgaJ/JpdfjFnYdqbWd72W/zLJ2cHqfBG9/Z6AKPzYSapTsgBhhpJ08PTrIW" +
            "kk0Yd7pJHNgUV+k0ZVLeK2zMCoWzXN93qFQ8e/b1V9+cZDVx/agHmS70XM/3GOVpRpP5XghZLOyETluWWdq4ceRSSbzAkqS89+vf1h/+9NrA" +
            "xkTGJ0dHfH593imzHGif6oRlYY1kaSaV08f3n2XKTwYLi3P9xLcFZIDG0L6hIUJ/oZDgbTcMo6TXDf3O4lLiUsKrEmKJN8Di2Shjy6uJaqkX" +
            "0iIjXW+099XB8aT1B/NdT6I6E866m9vk73cOMkgMHmRwZfv9pQHJxlkF5SEEMLHBbKFnYQJPx4dPjjIBROyHnaTfS3yqk4OFuWVWqb66tuyj" +
            "r1nMR8QWL779zrWrb74+cNvJs0f79z6/e/fL/cNRVgrWW3vr+ns3fnDt0jwdPfjLH27vFd2FUJKw41kuPfz07lFrewAHxyos2fnxa8f3D/M2" +
            "PRkWEvlJnRcOWBpQS5Y1YVDm0rbh1PXjyKqmadkIRc4rPvj8RqdysCYLktipxlNIdlBlcsjZinrdxQtLg9jm6enpaJoVVV1CEdWQsN/rJKuX" +
            "N8J0JCJ3fH9/LEwcQeKD0731GzfXhnf/+mDCdV7CKtfUVfhaYNleFHmqgVwBqUJxSJKShYGv+eM8Bb3CBBugeKLJM3j7iJL59Z2rGz0fQtGa" +
            "HBw8P5sURTrJud/rs3I0bQjElUhPT8Yt4SK+9O5accZW5yZ7j6cCmbChbsDgyEG3M9cl6XA4yaoGa1+udMlOCGRSz4/7g0jBcAUlCTh9lRfc" +
            "DjRiLxOfIr9C+OAVaXx2NhqP06KExVRXQKKpG277SS9hbYnvRp3AoTatp0W4/uYbg4CMHp76A5ry1bcWSF1BAFqRT4RkXUgVlhuETp2meZFN" +
            "J2nBKfNcaJ4fhHFvYSHxHJvU0+Eor6p8OCzsOImAsIwpFXlZy+LrS76/+8nz+Ru3Njz9mx9/8tHXZXfnJ9cX4IzHu7uPCsXmLq5Xe/+Kv39r" +
            "O/zveK4ffLw73vzgvSXn20wDjM85lohYNP0fJqXe0nffv5Ic7370oNID9sL1W1c6YrT36WdHwZUb31sEmj39/PY/2fWbl/m921+0Vz54uw9V" +
            "Ja+ne3+8M6SduSAb08Eca4OLV6One8+5qyanqYLCBkMRa1QuzNuZaF68bVLKon6f5cMJRsJ/tn8D"
        guard let compressed = Data(base64Encoded: encoded),
              let raw = try? (compressed as NSData).decompressed(using: .zlib) as Data else {
            preconditionFailure("Invalid bundled warmup animation")
        }
        let frameCount = 152, channelCount = 26, stride = 2 + (frameCount - 1)
        precondition(raw.count == channelCount * stride)
        var channels = Array(repeating: Array(repeating: Float(0), count: frameCount), count: channelCount)
        raw.withUnsafeBytes { buffer in
            for ch in 0..<channelCount {
                let base = ch * stride
                var value = Int(Int16(littleEndian: buffer.loadUnaligned(fromByteOffset: base, as: Int16.self)))
                channels[ch][0] = Float(value) / 400
                for f in 1..<frameCount {
                    value += Int(buffer.load(fromByteOffset: base + 2 + (f - 1), as: Int8.self))
                    channels[ch][f] = Float(value) / 400
                }
            }
        }
        let bones3D = [0, 1, 2, 4, 5, 7, 8]
        return (0..<frameCount).map { f in
            let hips = SIMD3<Float>(channels[0][f], channels[1][f], channels[2][f])
            var quats = Array(repeating: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1), count: 10)
            for (idx, bone) in bones3D.enumerated() {
                let c = 3 + idx * 3
                let x = channels[c][f], y = channels[c + 1][f], z = channels[c + 2][f]
                let w = sqrt(max(0, 1 - x * x - y * y - z * z))
                quats[bone] = simd_normalize(simd_quatf(ix: x, iy: y, iz: z, r: w))
            }
            for (idx, (bone, sign)) in [(6, Float(-1)), (9, Float(1))].enumerated() {
                let w = min(1, max(-1, channels[24 + idx][f]))
                let x = sign * sqrt(max(0, 1 - w * w))
                quats[bone] = simd_normalize(simd_quatf(ix: x, iy: 0, iz: 0, r: w))
            }
            return WarmupFrame(hips: hips, orientations: quats)
        }
    }()

    func poseWarmup(time: Float, reducedMotion: Bool) {
        let frames = Self.warmupFrames
        let count = frames.count
        let positiveTime = max(0, time)
        let framePos = reducedMotion ? 0 : (positiveTime * 24).truncatingRemainder(dividingBy: Float(count))
        let index0 = max(0, min(count - 1, Int(framePos)))
        let index1 = (index0 + 1) % count
        let frac = framePos - Float(index0)
        let f0 = frames[index0], f1 = frames[index1]
        let rhythm: Float = reducedMotion ? 0 : 1
        let breath = (sin(positiveTime * 2.1) + 1) * 0.5 * rhythm
        root.simdEulerAngles.z = 0
        bones[0].simdPosition = simd_mix(f0.hips, f1.hips, SIMD3<Float>(repeating: frac))
        for bone in bones {
            bone.simdScale = SIMD3<Float>(repeating: 1)
        }
        bones[1].simdScale = SIMD3<Float>(1 + breath * 0.008, 1 + breath * 0.005, 1 + breath * 0.012)
        for i in 0..<10 {
            var q1 = f1.orientations[i]
            if simd_dot(f0.orientations[i].vector, q1.vector) < 0 {
                q1 = simd_quatf(vector: -q1.vector)
            }
            bones[i].simdOrientation = simd_normalize(simd_slerp(f0.orientations[i], q1, frac))
        }
        bones[3].simdEulerAngles.y = isRival ? -0.025 : 0.025
        // Solve legs in hip-local space to stationary canvas targets so boots stay
        // planted on the mat while the pelvis and torso bounce, pivot, and weave.
        let stepIn = ease((framePos - 48) / 12)
        let stepOut = ease((framePos - 130) / 12)
        let stance = stepIn * (1 - stepOut)
        let stepArc = (4 * stepIn * (1 - stepIn) + 4 * stepOut * (1 - stepOut)) * rhythm
        for side in 0..<2 {
            let sign: Float = side == 0 ? -1 : 1
            let bouncePhase = positiveTime * 7.5 + (side == 0 ? 0 : .pi)
            let toeBounce = max(0, sin(bouncePhase)) * 0.012 * (1 - stance) * rhythm
            let lift = toeBounce + stepArc * (side == 0 ? 0.018 : 0.024)
            let offset = SIMD3<Float>(
                sign * (0.04 + 0.01 * stance),
                lift,
                sign * (0.02 + 0.11 * stance)
            )
            poseLeg(side, target: bindPositions[12 + side * 3] + offset)
        }
        forwardDrive = 0
        slip = 0
    }
}

/// HMR1 is built offline by scripts/rig_fighters.py. Vertex colors, normals
/// and packed skinning buffers go directly to SceneKit's Metal skinning path.
@MainActor private struct FighterRig {
    let bones: [SCNNode]
    let positions: [SIMD3<Float>]
    let skeleton: SCNNode
    let mesh: SCNNode

    private static var loggedFailures = Set<String>()

    private static func assetData(_ asset: FighterModelAsset) -> Data? {
        guard let url = Bundle.main.url(forResource: asset.rawValue, withExtension: "fighter"),
              let data = try? Data(contentsOf: url),
              data.count >= 16, data.prefix(4) == Data("HMR1".utf8) else { return nil }
        func uint(_ offset: Int) -> UInt32 { data.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) } }
        let vertices = Int(uint(4)), indices = Int(uint(8)), bones = Int(uint(12))
        guard bones == 16, vertices > 0, indices > 0, indices % 3 == 0 else { return nil }
        let vertexStart = 16 + bones * 16
        let indexStart = vertexStart + vertices * 60
        guard data.count == indexStart + indices * 4 else { return nil }
        for i in 0..<bones {
            let offset = 16 + i * 16
            let parent = Int(Int32(bitPattern: uint(offset)))
            guard parent >= -1, parent < i else { return nil }
            for lane in 1...3 {
                guard Float(bitPattern: uint(offset + lane * 4)).isFinite else { return nil }
            }
        }
        for i in 0..<vertices {
            let offset = vertexStart + i * 60
            for lane in 0..<13 {
                guard Float(bitPattern: uint(offset + lane * 4)).isFinite else { return nil }
            }
            var totalWeight: Float = 0
            for lane in 0..<4 {
                let weight = Float(bitPattern: uint(offset + 36 + lane * 4))
                let bone = data.withUnsafeBytes { UInt16(littleEndian: $0.loadUnaligned(fromByteOffset: offset + 52 + lane * 2, as: UInt16.self)) }
                guard weight >= 0, weight <= 1, bone < UInt16(bones) else { return nil }
                totalWeight += weight
            }
            guard abs(totalWeight - 1) < 0.001 else { return nil }
        }
        for i in 0..<indices {
            guard uint(indexStart + i * 4) < UInt32(vertices) else { return nil }
        }
        return data
    }

    static func load(_ asset: FighterModelAsset) -> FighterRig {
        let data: Data
        if let requested = assetData(asset) {
            data = requested
        } else {
            if loggedFailures.insert(asset.rawValue).inserted {
                NSLog("Unavailable fighter asset %@.fighter; falling back to mack.fighter", asset.rawValue)
            }
            guard asset != .mack, let fallback = assetData(.mack) else {
                preconditionFailure("Missing or malformed bundled fallback fighter rig: mack")
            }
            data = fallback
        }
        func uint(_ offset: Int) -> UInt32 { data.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) } }
        func float(_ offset: Int) -> Float { Float(bitPattern: uint(offset)) }
        precondition(data.count >= 16 && data.prefix(4) == Data("HMR1".utf8), "Invalid fighter header")
        let vertexCount = Int(uint(4)), indexCount = Int(uint(8)), boneCount = Int(uint(12))
        precondition(boneCount == 16 && indexCount % 3 == 0)
        let vertexStart = 16 + boneCount * 16
        let indexStart = vertexStart + vertexCount * 60
        precondition(data.count == indexStart + indexCount * 4, "Invalid fighter payload")
        let names = ["hips", "spine", "neck", "head", "leftShoulder", "leftElbow", "leftHand", "rightShoulder", "rightElbow", "rightHand", "leftHip", "leftKnee", "leftFoot", "rightHip", "rightKnee", "rightFoot"]
        let skeleton = SCNNode()
        skeleton.name = "skeleton"
        var bones: [SCNNode] = [], positions: [SIMD3<Float>] = [], inverseBind: [NSValue] = []
        for i in 0..<boneCount {
            let offset = 16 + i * 16
            let parent = Int(Int32(bitPattern: uint(offset)))
            precondition(parent >= -1 && parent < i)
            let position = SIMD3<Float>(float(offset + 4), float(offset + 8), float(offset + 12))
            let bone = SCNNode()
            bone.name = names[i]
            bone.simdPosition = position - (parent >= 0 ? positions[parent] : .zero)
            (parent >= 0 ? bones[parent] : skeleton).addChildNode(bone)
            bones.append(bone)
            positions.append(position)
            var inverse = matrix_identity_float4x4
            inverse.columns.3 = SIMD4<Float>(-position, 1)
            inverseBind.append(NSValue(scnMatrix4: SCNMatrix4(inverse)))
        }
        let vertices = data.subdata(in: vertexStart..<indexStart)
        func source(_ semantic: SCNGeometrySource.Semantic, _ offset: Int, _ components: Int) -> SCNGeometrySource {
            SCNGeometrySource(data: vertices, semantic: semantic, vectorCount: vertexCount, usesFloatComponents: true, componentsPerVector: components, bytesPerComponent: 4, dataOffset: offset, dataStride: 60)
        }
        let element = SCNGeometryElement(data: data.subdata(in: indexStart..<data.count), primitiveType: .triangles, primitiveCount: indexCount / 3, bytesPerIndex: 4)
        let geometry = SCNGeometry(sources: [source(.vertex, 0, 3), source(.normal, 12, 3), source(.color, 24, 3)], elements: [element])
        let material = SCNMaterial()
        material.lightingModel = .physicallyBased
        material.diffuse.contents = UIColor.white
        material.roughness.contents = 0.65
        geometry.materials = [material]
        let mesh = SCNNode(geometry: geometry)
        mesh.name = "skinnedMesh"
        // SceneKit requires packed skinning buffers here; interleaved sources
        // can silently return a nil skinner even when geometry renders correctly.
        var weights = [Float](), indices = [UInt16]()
        for i in 0..<vertexCount {
            for lane in 0..<4 {
                weights.append(float(vertexStart + i * 60 + 36 + lane * 4))
                let offset = vertexStart + i * 60 + 52 + lane * 2
                indices.append(data.withUnsafeBytes { UInt16(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt16.self)) })
            }
        }
        let weightSource = SCNGeometrySource(data: weights.withUnsafeBytes { Data($0) }, semantic: .boneWeights, vectorCount: vertexCount, usesFloatComponents: true, componentsPerVector: 4, bytesPerComponent: 4, dataOffset: 0, dataStride: 16)
        let indexSource = SCNGeometrySource(data: indices.withUnsafeBytes { Data($0) }, semantic: .boneIndices, vectorCount: vertexCount, usesFloatComponents: false, componentsPerVector: 4, bytesPerComponent: 2, dataOffset: 0, dataStride: 8)
        mesh.skinner = SCNSkinner(baseGeometry: geometry, bones: bones, boneInverseBindTransforms: inverseBind, boneWeights: weightSource, boneIndices: indexSource)
        precondition(mesh.skinner != nil, "SceneKit rejected fighter skinning sources")
        // Keep the mesh eligible for culling after its T-pose arms move forward.
        mesh.boundingBox = (SCNVector3(-1.6, -0.2, -1.2), SCNVector3(1.6, 3.1, 1.2))
        return FighterRig(bones: bones, positions: positions, skeleton: skeleton, mesh: mesh)
    }
}
