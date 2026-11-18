import AppKit
import SceneKit
import SwiftUI
import simd

enum BobbleheadCamera {
    static let fullFigureAzimuth = -37.0 * Double.pi / 180
    static let stockPosition = SIMD3<Double>(1.37, 2.75, 8)

    static func facesLeft(yaw: Double, isFullFigure: Bool) -> Bool {
        let azimuth = isFullFigure ? fullFigureAzimuth : atan2(stockPosition.x, stockPosition.z)
        return sin(yaw - azimuth) < -1e-6
    }
}

@MainActor
final class BobbleheadModel {
    private let template: SCNNode
    private let figureDimensions: FigureDimensions

    init(url: URL) throws {
        let scene = try SCNScene(url: url, options: [.convertToYUp: true])
        let content = scene.rootNode.clone()
        let fitted = SCNNode()
        fitted.addChildNode(content)
        Self.removeSceneSettings(from: content)
        content.enumerateChildNodes { node, _ in Self.removeSceneSettings(from: node) }

        guard let parts = FigureParts(in: content), let bounds = try Bounds(measuring: content, in: fitted),
              try Bounds(measuring: parts.head, in: fitted) != nil,
              try Bounds(measuring: parts.body, in: fitted) != nil,
              try Bounds(measuring: parts.spring, in: fitted) != nil else {
            throw ModelError.invalidGeometry
        }
        let scale = try bounds.scaleToFit(width: 2.42, height: 3.2)
        let bodyOrigin = parts.body.simdConvertPosition(.zero, to: fitted)
        let headOrigin = parts.head.simdConvertPosition(.zero, to: fitted)
        let springOrigin = parts.spring.simdConvertPosition(.zero, to: fitted)
        let springHeight = (headOrigin.y - springOrigin.y) * scale
        guard bodyOrigin.x.isFinite, bodyOrigin.z.isFinite, springHeight.isFinite, springHeight > 0 else {
            throw ModelError.invalidGeometry
        }

        fitted.simdScale = SIMD3(repeating: scale)
        fitted.simdPosition = -SIMD3(bodyOrigin.x, bounds.minimum.y, bodyOrigin.z) * scale

        let assembly = SCNNode()
        assembly.addChildNode(fitted)
        template = assembly
        figureDimensions = FigureDimensions(height: bounds.size.y * scale, springHeight: springHeight)
    }

    fileprivate func makeFigure() -> Figure? {
        let root = template.clone()
        guard let parts = FigureParts(in: root) else { return nil }
        let head = Self.mount(parts.head, under: root)
        let spring = Self.mount(parts.spring, under: root)
        return Figure(root: root, head: head, spring: spring, dimensions: figureDimensions)
    }

    private static func removeSceneSettings(from node: SCNNode) {
        node.camera = nil
        node.light = nil
        node.removeAllAnimations()
    }

    private static func mount(_ node: SCNNode, under root: SCNNode) -> SCNNode {
        // Keep the imported transform, including Blender's up-axis conversion,
        // beneath a pivot that moves in SceneKit's coordinate system.
        let transform = node.simdConvertTransform(matrix_identity_float4x4, to: root)
        let pivot = SCNNode()
        pivot.simdPosition = node.simdConvertPosition(.zero, to: root)
        root.addChildNode(pivot)
        pivot.addChildNode(node)
        node.simdTransform = pivot.simdTransform.inverse * transform
        return pivot
    }

    fileprivate struct Figure {
        let root: SCNNode
        let head: SCNNode
        let spring: SCNNode
        let dimensions: FigureDimensions
    }

    fileprivate struct FigureDimensions {
        let height: Float
        let springHeight: Float
    }

    private struct FigureParts {
        let head: SCNNode
        let body: SCNNode
        let spring: SCNNode

        init?(in root: SCNNode) {
            guard let head = root.childNode(withName: "BopHead", recursively: true),
                  let body = root.childNode(withName: "BopBody", recursively: true),
                  let spring = root.childNode(withName: "BopSpring", recursively: true),
                  head.parent === body.parent, spring.parent === body.parent else { return nil }
            self.head = head
            self.body = body
            self.spring = spring
        }
    }

    private struct Bounds {
        private(set) var minimum = SIMD3<Float>(repeating: .infinity)
        private var maximum = SIMD3<Float>(repeating: -.infinity)

        var size: SIMD3<Float> { maximum - minimum }

        init?(measuring root: SCNNode, in space: SCNNode) throws {
            for node in [root] + root.childNodes(passingTest: { _, _ in true }) {
                guard let geometry = node.geometry,
                      geometry.elements.contains(where: { $0.primitiveCount > 0 }) else { continue }

                var ancestor: SCNNode? = node
                while let current = ancestor, !current.isHidden {
                    ancestor = current.parent
                }
                if ancestor != nil { continue }

                let (low, high) = geometry.boundingBox
                for x in [low.x, high.x] {
                    for y in [low.y, high.y] {
                        for z in [low.z, high.z] {
                            let corner = node.simdConvertPosition(SIMD3(Float(x), Float(y), Float(z)), to: space)
                            guard corner.x.isFinite, corner.y.isFinite, corner.z.isFinite else {
                                throw ModelError.invalidGeometry
                            }
                            minimum = simd_min(minimum, corner)
                            maximum = simd_max(maximum, corner)
                        }
                    }
                }
            }
            guard minimum.x.isFinite else { return nil }
        }

        func scaleToFit(width: Float, height: Float) throws -> Float {
            guard size.x.isFinite, size.y.isFinite, size.z.isFinite else {
                throw ModelError.invalidGeometry
            }
            let scale = min(width / max(size.x, size.z), height / size.y)
            guard scale.isFinite, scale > 0 else { throw ModelError.invalidGeometry }
            return scale
        }
    }

    private enum ModelError: Error {
        case invalidGeometry
    }
}

struct BobbleheadToy: View, Animatable {
    typealias HeadPose = AnimatablePair<AnimatablePair<Double, Double>, AnimatablePair<Double, Double>>

    nonisolated var pitch: Double
    nonisolated var roll: Double
    nonisolated var yaw: Double
    nonisolated var lift: Double
    let model: BobbleheadModel?
    nonisolated var figureYaw: Double

    nonisolated var animatableData: AnimatablePair<HeadPose, Double> {
        get { .init(.init(.init(pitch, roll), .init(yaw, lift)), figureYaw) }
        set {
            pitch = newValue.first.first.first
            roll = newValue.first.first.second
            yaw = newValue.first.second.first
            lift = newValue.first.second.second
            figureYaw = newValue.second
        }
    }

    var body: some View {
        BobbleheadScene(
            pitch: pitch,
            roll: roll,
            yaw: yaw,
            lift: lift,
            model: model,
            figureYaw: figureYaw
        )
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct BobbleheadScene: NSViewRepresentable {
    let pitch: Double
    let roll: Double
    let yaw: Double
    let lift: Double
    let model: BobbleheadModel?
    let figureYaw: Double

    func makeCoordinator() -> ToyScene { ToyScene(model: model) }

    func makeNSView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = .clear
        view.scene = context.coordinator.scene
        view.pointOfView = context.coordinator.camera
        view.antialiasingMode = .multisampling4X
        return view
    }

    func updateNSView(_ view: SCNView, context: Context) {
        context.coordinator.updatePose(pitch: pitch, roll: roll, yaw: yaw, lift: lift, figureYaw: figureYaw)
    }
}

@MainActor
private final class ToyScene {
    static let springHeight: CGFloat = 0.40
    static let springBottom: CGFloat = 1.05
    static let springTop = springBottom + springHeight

    let scene = SCNScene()
    let camera = SCNNode()
    private let head = SCNNode()
    private let spring = SCNNode()
    private let presentationRoot = SCNNode()
    private let figure: BobbleheadModel.Figure?
    private let neutralHeadY: Float

    init(model: BobbleheadModel?) {
        figure = model?.makeFigure()
        neutralHeadY = figure?.head.simdPosition.y ?? 0
        scene.rootNode.addChildNode(presentationRoot)
        if let figure {
            presentationRoot.addChildNode(figure.root)
        } else {
            makeStockFigure()
        }

        let lens = SCNCamera()
        lens.usesOrthographicProjection = true
        camera.camera = lens
        scene.rootNode.addChildNode(camera)
        frameFigure()

        light(.ambient, 0xFFF2E0, 540, at: SCNVector3Zero)
        light(.directional, 0xFFF5E8, 1050, at: SCNVector3(-3, 5, 6))
        light(.directional, 0xFFE1B4, 620, at: SCNVector3(3, 4, -3))
        light(.directional, 0xE2E9FF, 180, at: SCNVector3(4, 1, 4))
    }

    private func makeStockFigure() {
        let root = SCNNode()
        presentationRoot.addChildNode(root)
        let vinyl = material(0xF66537, gloss: 0.37)
        let jacket = material(0xC74424, gloss: 0.26)
        let shoes = material(0x7F2C21, gloss: 0.20)
        let face = material(0x321711, gloss: 0.20)
        let base = material(0x312623, gloss: 0.24)
        let trim = material(0x885944, gloss: 0.44)
        let steel = material(0x594944, gloss: 0.64)
        let porcelain = material(0xFFF8ED, gloss: 0.72)
        let vent = material(0x3B3531, gloss: 0.1)

        cylinder(0.91, 0.26, bevel: 0.08, base, at: SCNVector3(0, 0.16, 0), on: root)
        cylinder(0.875, 0.025, bevel: 0.007, trim, at: SCNVector3(0, 0.253, 0), on: root)
        cylinder(0.78, 0.05, bevel: 0.024, base, at: SCNVector3(0, 0.30, 0), on: root)

        for side in [-1.0, 1.0] {
            oval(0.25, 0.135, 0.27, shoes, at: SCNVector3(side * 0.255, 0.414, 0.12), on: root)
            let arm = oval(0.15, 0.245, 0.17, vinyl, at: SCNVector3(side * 0.45, 0.72, 0.01), on: root)
            arm.eulerAngles.z = side * 0.23
        }
        roundedBox(0.89, 0.64, 0.64, radius: 0.29, jacket, at: SCNVector3(0, 0.747, 0), on: root)
        roundedBox(0.11, 0.05, 0.02, radius: 0.01, porcelain, at: SCNVector3(0.18, 0.81, 0.315), on: root)
        cylinder(0.20, 0.06, bevel: 0.022, base, at: SCNVector3(0, Self.springBottom, 0), on: root)

        spring.position.y = Self.springBottom
        let coils = tube(segments: 112, radius: 0.034) { t in
            let angle = t * 8 * Float.pi
            return SIMD3(0.143 * cos(angle), 0.027 + Float(Self.springHeight - 0.055) * t, 0.143 * sin(angle))
        }
        add(coils, steel, at: SCNVector3Zero, on: spring)
        root.addChildNode(spring)

        head.position.y = Self.springTop
        root.addChildNode(head)
        cylinder(0.20, 0.065, bevel: 0.024, base, at: SCNVector3(0, 0.022, 0), on: head)
        roundedBox(2.15, 1.67, 1.40, radius: 0.63, vinyl, at: SCNVector3(0, 0.84, 0), on: head)

        for side in [-1.0, 1.0] {
            oval(0.101, 0.146, 0.033, face, at: SCNVector3(side * 0.373, 0.91, 0.697), on: head)
            let pod = SCNNode()
            pod.position = SCNVector3(side * 0.94, 0.72, 0.56)
            pod.eulerAngles.z = side * 0.18
            head.addChildNode(pod)
            roundedBox(0.132, 0.42, 0.145, radius: 0.065, porcelain, at: SCNVector3(0, -0.16, 0.045), on: pod)
            oval(0.166, 0.169, 0.152, porcelain, at: SCNVector3(side * 0.026, 0.036, 0.022), on: pod)
            oval(0.039, 0.022, 0.009, vent, at: SCNVector3(-side * 0.018, 0.057, 0.166), on: pod)
        }

        let smile = tube(segments: 32, radius: 0.018) { t in
            let x = (t - 0.5) * 0.32
            return SIMD3(x, 0.663 + 2.2 * x * x, 0.709)
        }
        add(smile, face, at: SCNVector3Zero, on: head)
        for side in [-1.0, 1.0] {
            oval(0.018, 0.018, 0.018, face, at: SCNVector3(side * 0.16, 0.7193, 0.709), on: head)
        }
    }

    func updatePose(pitch: Double, roll: Double, yaw: Double, lift: Double, figureYaw: Double) {
        presentationRoot.eulerAngles.y = figureYaw
        let lift = min(0.17, max(-0.12, lift))
        let pitchRotation = simd_quatf(angle: Float(pitch), axis: SIMD3(1, 0, 0))
        let yawRotation = simd_quatf(angle: Float(yaw), axis: SIMD3(0, 1, 0))
        let rollRotation = simd_quatf(angle: Float(roll), axis: SIMD3(0, 0, 1))
        // Turning the head carries its tilt with it instead of compounding it.
        let headRotation = yawRotation * rollRotation * pitchRotation
        guard let figure else {
            head.simdOrientation = headRotation
            head.position.y = Self.springTop + lift
            spring.scale.y = 1 + lift / Self.springHeight
            return
        }

        figure.head.simdOrientation = headRotation
        let figureLift = max(Float(lift), -0.85 * figure.dimensions.springHeight)
        figure.head.simdPosition.y = neutralHeadY + figureLift
        figure.spring.simdScale.y = 1 + figureLift / figure.dimensions.springHeight
    }

    private func frameFigure() {
        camera.camera?.orthographicScale = 1.91
        guard let figure else {
            let position = BobbleheadCamera.stockPosition
            camera.position = SCNVector3(position.x, position.y, position.z)
            camera.look(at: SCNVector3(0, 1.57, 0))
            return
        }

        let centerY = CGFloat(figure.dimensions.height) / 2
        let distance = 8.0
        let azimuth = BobbleheadCamera.fullFigureAzimuth
        let elevation = 10.0 * Double.pi / 180
        camera.position = SCNVector3(
            distance * cos(elevation) * sin(azimuth),
            centerY + distance * sin(elevation),
            distance * cos(elevation) * cos(azimuth)
        )
        camera.look(at: SCNVector3(0, centerY, 0))
    }

    private func material(_ hex: UInt32, gloss: CGFloat) -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .blinn
        material.diffuse.contents = color(hex)
        material.specular.contents = NSColor(white: 1, alpha: 1)
        material.specular.intensity = gloss
        material.shininess = 0.46
        return material
    }

    private func color(_ hex: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 255) / 255,
            green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255,
            alpha: 1
        )
    }

    private func light(_ type: SCNLight.LightType, _ hex: UInt32, _ intensity: CGFloat, at position: SCNVector3) {
        let light = SCNLight()
        light.type = type
        light.color = color(hex)
        light.intensity = intensity
        let node = SCNNode()
        node.light = light
        node.position = position
        if type != .ambient { node.look(at: SCNVector3(0, 1.5, 0)) }
        scene.rootNode.addChildNode(node)
    }

    @discardableResult
    private func add(_ geometry: SCNGeometry, _ material: SCNMaterial, at position: SCNVector3, on parent: SCNNode) -> SCNNode {
        geometry.firstMaterial = material
        let node = SCNNode(geometry: geometry)
        node.position = position
        parent.addChildNode(node)
        return node
    }

    @discardableResult
    private func oval(_ x: CGFloat, _ y: CGFloat, _ z: CGFloat, _ material: SCNMaterial, at position: SCNVector3, on parent: SCNNode) -> SCNNode {
        let shape = SCNSphere(radius: 1)
        shape.segmentCount = 36
        let node = add(shape, material, at: position, on: parent)
        node.scale = SCNVector3(x, y, z)
        return node
    }

    private func roundedBox(_ width: CGFloat, _ height: CGFloat, _ length: CGFloat, radius: CGFloat, _ material: SCNMaterial, at position: SCNVector3, on parent: SCNNode) {
        let shape = SCNBox(width: width, height: height, length: length, chamferRadius: radius)
        shape.chamferSegmentCount = 24
        add(shape, material, at: position, on: parent)
    }

    private func cylinder(_ radius: CGFloat, _ height: CGFloat, bevel: CGFloat, _ material: SCNMaterial, at position: SCNVector3, on parent: SCNNode) {
        // Use a lathed profile to keep the short bevels separate from the flat top and bottom.
        let profile: [SIMD2<Float>] = [
            .init(0, Float(-height / 2)),
            .init(Float(radius - bevel), Float(-height / 2)),
            .init(Float(radius), Float(-height / 2 + bevel)),
            .init(Float(radius), Float(height / 2 - bevel)),
            .init(Float(radius - bevel), Float(height / 2)),
            .init(0, Float(height / 2))
        ]
        add(lathe(profile), material, at: position, on: parent)
    }

    private func lathe(_ profile: [SIMD2<Float>]) -> SCNGeometry {
        let sides = 72
        var vertices: [SCNVector3] = []
        var normals: [SCNVector3] = []
        var indices: [UInt32] = []
        for (start, end) in zip(profile, profile.dropFirst()) {
            let direction = simd_normalize(end - start)
            let first = UInt32(vertices.count)
            for side in 0...sides {
                let angle = Float(side) / Float(sides) * 2 * .pi
                let x = cos(angle)
                let z = sin(angle)
                vertices.append(SCNVector3(start.x * x, start.y, start.x * z))
                vertices.append(SCNVector3(end.x * x, end.y, end.x * z))
                let normal = SCNVector3(direction.y * x, -direction.x, direction.y * z)
                normals.append(contentsOf: [normal, normal])
                if side < sides {
                    let index = first + UInt32(side * 2)
                    indices.append(contentsOf: [index, index + 1, index + 2, index + 1, index + 3, index + 2])
                }
            }
        }
        return geometry(vertices, normals, indices)
    }

    private func tube(segments: Int, radius: Float, point: (Float) -> SIMD3<Float>) -> SCNGeometry {
        let sides = 10
        var vertices: [SCNVector3] = []
        var normals: [SCNVector3] = []
        var indices: [UInt32] = []
        for step in 0...segments {
            let t = Float(step) / Float(segments)
            let center = point(t)
            let tangent = simd_normalize(point(min(1, t + 0.001)) - point(max(0, t - 0.001)))
            let first = simd_normalize(simd_cross(tangent, SIMD3(0, 1, 0)))
            let second = simd_cross(tangent, first)
            for side in 0..<sides {
                let angle = Float(side) * 2 * .pi / Float(sides)
                let normal = cos(angle) * first + sin(angle) * second
                let position = center + radius * normal
                vertices.append(SCNVector3(position.x, position.y, position.z))
                normals.append(SCNVector3(normal.x, normal.y, normal.z))
                if step < segments {
                    let current = UInt32(step * sides + side)
                    let next = UInt32(step * sides + (side + 1) % sides)
                    indices.append(contentsOf: [current, next, current + UInt32(sides), next, next + UInt32(sides), current + UInt32(sides)])
                }
            }
        }
        return geometry(vertices, normals, indices)
    }

    private func geometry(_ vertices: [SCNVector3], _ normals: [SCNVector3], _ indices: [UInt32]) -> SCNGeometry {
        SCNGeometry(
            sources: [.init(vertices: vertices), .init(normals: normals)],
            elements: [.init(indices: indices, primitiveType: .triangles)]
        )
    }
}
