// BlackHoleDelete — UIKit + Metal driver.
//
// Three views, all covering the whole screen and aligned with window coordinates:
//   backdropView — above the wallpaper, below the chat list (opaque wallpaper replacement);
//   meshView     — above the chat list (the swallowed messages);
//   overlayView  — above everything incl. the navigation bar (black island shape + light ring).
// See README.md for the integration into Telegram-iOS.

import MetalKit
import UIKit

/// A message to swallow: its frame in window coordinates and a snapshot of exactly that size.
public struct BlackHoleSwallowItem {
    public let id: Int
    public let frame: CGRect
    public let image: CGImage
    public init(id: Int, frame: CGRect, image: CGImage) {
        self.id = id
        self.frame = frame
        self.image = image
    }
}

public final class BlackHoleDeleteAnimator {
    public let config: BlackHoleConfig
    public let backdropView: UIView
    public let meshView: UIView
    public let overlayView: UIView

    /// Called every frame while running. Use `state.presence` to hide the navigation bar and the
    /// status bar (> 0.12) and to bring them back when it drops.
    public var onUpdate: ((BlackHoleState) -> Void)?
    /// Everything is swallowed: show the empty state and the "Chat cleared" toast now.
    public var onSwallowed: (() -> Void)?
    /// The hole has landed back into the island; all views are hidden again.
    public var onCompletion: (() -> Void)?

    public private(set) var isRunning = false

    /// Bundle with the compiled shaders and the disk texture: `<name>.bundle` next to this module's
    /// binary (Bazel `apple_resource_bundle`, see BUILD), or the module bundle itself.
    public static func resourceBundle(named name: String = "BlackHoleDeleteResourcesBundle") -> Bundle {
        let moduleBundle = Bundle(for: BlackHoleRenderer.self)
        if let path = moduleBundle.path(forResource: name, ofType: "bundle"), let bundle = Bundle(path: path) {
            return bundle
        }
        return moduleBundle
    }

    private let renderer: BlackHoleRenderer
    private let backdrop: BlackHoleMetalView
    private let mesh: BlackHoleMetalView
    private let overlay: BlackHoleMetalView
    private var link: CADisplayLink?
    private var run: BlackHoleRun?
    private var time: Double = 0
    private var lastTick: CFTimeInterval = 0
    private var swallowedReported = false
    private var wallpaperTexture: MTLTexture?
    private var itemTextures: [Int: MTLTexture] = [:]
    private var preparedTextures: [Int: (image: CGImage, texture: MTLTexture)] = [:]

    /// - Parameter bundle: bundle with the compiled `BlackHole.metal` (default.metallib) and
    ///   `BlackHoleDisk.png`. In Telegram-iOS — the bundle of the module that contains them.
    public init?(config: BlackHoleConfig = .default, bundle: Bundle = .main) {
        guard let renderer = BlackHoleRenderer(bundle: bundle) else { return nil }
        self.config = config
        self.renderer = renderer
        backdrop = BlackHoleMetalView(device: renderer.device, opaque: true)
        mesh = BlackHoleMetalView(device: renderer.device, opaque: false)
        overlay = BlackHoleMetalView(device: renderer.device, opaque: false)
        backdropView = backdrop
        meshView = mesh
        overlayView = overlay
        for view in [backdrop, mesh, overlay] { view.isHidden = true }
    }

    /// Compiles pipelines and uploads the disk texture off the main thread. Call when the chat
    /// screen appears — otherwise the first run waits for shader compilation.
    public func prewarm() {
        renderer.prewarm()
        warmDrawables(attempt: 0)
    }

    /// One empty frame into each view once they have a size: the first drawable of a full-screen
    /// CAMetalLayer is expensive (~0.1 s) and would otherwise land on the first animation frame.
    private func warmDrawables(attempt: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, !self.isRunning else { return }
            let views = [self.backdrop, self.mesh, self.overlay]
            guard views.allSatisfy({ $0.bounds.width > 0 && $0.window != nil }) else {
                if attempt < 20 { self.warmDrawables(attempt: attempt + 1) }
                return
            }
            for view in views {
                view.alpha = 0
                view.isHidden = false
                view.render { _, _, _ in }
                view.isHidden = true
                view.alpha = 1
            }
        }
    }

    /// Optional: upload message snapshots ahead of time (e.g. while the confirmation sheet is
    /// shown). `start` reuses textures whose id and image match.
    public func prepare(items: [BlackHoleSwallowItem]) {
        let device = renderer.device
        DispatchQueue.global(qos: .userInitiated).async {
            let made = items.compactMap { item in
                BlackHoleRenderer.makeTexture(device: device, image: item.image).map { (item, $0) }
            }
            DispatchQueue.main.async {
                for (item, texture) in made { self.preparedTextures[item.id] = (item.image, texture) }
            }
        }
    }

    /// Starts the animation. Textures are prepared off the main thread first (a few dozen ms),
    /// then the first frame is drawn and `onStart` is called — hide the real messages (and the
    /// wallpaper, if given) in `onStart`, the animator draws them from that frame on.
    /// - Parameters:
    ///   - items: visible messages to swallow (off-screen ones simply disappear).
    ///   - wallpaper: snapshot of the chat wallpaper at screen size (nil — no lens/shade/bloom).
    ///   - island: Dynamic Island frame in window coordinates (see `BlackHoleLayout.islandRect`).
    public func start(items: [BlackHoleSwallowItem], wallpaper: CGImage?, island: CGRect, onStart: (() -> Void)? = nil) {
        cancel()
        isRunning = true
        let device = renderer.device
        let prepared = preparedTextures
        preparedTextures = [:]
        let generation = UUID()
        startGeneration = generation
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            var textures: [Int: MTLTexture] = [:]
            for item in items {
                if let ready = prepared[item.id], ready.image === item.image {
                    textures[item.id] = ready.texture
                } else if let texture = BlackHoleRenderer.makeTexture(device: device, image: item.image) {
                    textures[item.id] = texture
                }
            }
            let wallpaperTexture = wallpaper.flatMap { BlackHoleRenderer.makeTexture(device: device, image: $0, mipmapped: false) }
            DispatchQueue.main.async {
                guard let self, self.startGeneration == generation else { return }
                self.begin(items: items, textures: textures, wallpaper: wallpaperTexture, island: island)
                onStart?()
            }
        }
    }

    private var startGeneration: UUID?

    private func begin(items: [BlackHoleSwallowItem], textures: [Int: MTLTexture], wallpaper: MTLTexture?, island: CGRect) {
        run = BlackHoleRun(items: items.map { BlackHoleItem(id: $0.id, frame: $0.frame) }, island: island, config: config)
        itemTextures = textures
        wallpaperTexture = wallpaper
        time = 0
        swallowedReported = false
        backdrop.isHidden = wallpaperTexture == nil
        mesh.isHidden = false
        overlay.isHidden = false

        lastTick = CACurrentMediaTime()
        let link = CADisplayLink(target: DisplayLinkTarget { [weak self] in self?.tick() }, selector: #selector(DisplayLinkTarget.fire))
        if #available(iOS 15.0, *) {
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        }
        link.add(to: .main, forMode: .common)
        self.link = link
        render()
    }

    /// Stops immediately and hides everything (no completion callback).
    public func cancel() {
        startGeneration = nil
        link?.invalidate()
        link = nil
        run = nil
        isRunning = false
        itemTextures = [:]
        wallpaperTexture = nil
        for view in [backdrop, mesh, overlay] { view.isHidden = true }
    }

    private func tick() {
        guard let run else { return }
        let now = CACurrentMediaTime()
        if ProcessInfo.processInfo.environment["BLACKHOLE_DEBUG_FRAMES"] != nil, now - lastTick > 0.025 {
            print(String(format: "BlackHole slow frame %.0f ms at t=%.2f", (now - lastTick) * 1000, time))
        }
        // Time advances by frames with a capped step: after a dropped frame the animation continues
        // from where it was instead of jumping ahead.
        time += min(now - lastTick, 1.0 / 30)
        lastTick = now
        if !swallowedReported && time >= run.swallowEnd {
            swallowedReported = true
            onSwallowed?()
        }
        if time >= run.total {
            cancel()
            onCompletion?()
            return
        }
        render()
    }

    private func render() {
        guard let run else { return }
        let state = BlackHoleState.at(time, run: run)
        onUpdate?(state)
        let c = run.config
        let tau = time - run.swallowStart

        if let wallpaper = wallpaperTexture {
            backdrop.render { [renderer] encoder, size, scale in
                var u = BackdropUniformsCPU(
                    view: SIMD4(Float(size.width), Float(size.height), Float(scale), Float(state.time)),
                    hole: SIMD4(Float(state.center.x), Float(state.center.y), Float(state.radius), Float(state.presence)),
                    shape: SIMD4(Float(state.halfSize.width), Float(state.halfSize.height),
                                 Float(state.presence * c.lensStrength), Float(state.presence * c.backgroundSwirl)),
                    space: SIMD4(Float(state.presence * c.spaceDarkness), Float(c.spaceSize),
                                 Float(state.time * state.presence * c.backgroundSpin), Float(c.glow)))
                renderer.drawBackdrop(encoder: encoder, uniforms: &u, wallpaper: wallpaper)
            }
        }

        mesh.render { [renderer, itemTextures] encoder, size, scale in
            for item in run.items {
                guard let texture = itemTextures[item.id], item.frame.width > 0, item.frame.height > 0 else { continue }
                // Grid cell ~6 pt: smooth enough for the arc bend and the "spaghetti".
                let cols = max(4, Int(item.frame.width / 6)), rows = max(3, Int(item.frame.height / 6))
                var u = MeshUniformsCPU(
                    view: SIMD4(Float(size.width), Float(size.height), Float(scale), 0),
                    hole: SIMD4(Float(state.center.x), Float(state.center.y), Float(state.radius), Float(tau)),
                    flow: SIMD4(Float(run.flowSpeed), Float(c.pullStrength), Float(c.pullReach * Double(c.holeRadius)), Float(c.flowRamp)),
                    extra: SIMD4(Float(c.sinkDepth), 0, Float(c.arcShape), Float(c.flowAccel)),
                    fade: SIMD4(Float(c.fadeOuter), Float(min(c.fadeInner, c.fadeOuter - 0.05)), Float(c.fadeBlur),
                                Float(state.presence * c.emergePull)),
                    frame: SIMD4(Float(item.frame.minX), Float(item.frame.minY), Float(item.frame.width), Float(item.frame.height)),
                    grid: SIMD4(Float(cols), Float(rows), 0, 0))
                renderer.drawMesh(encoder: encoder, uniforms: &u, texture: texture, vertexCount: cols * rows * 6)
            }
        }

        overlay.render { [renderer] encoder, size, scale in
            var u = OverlayUniformsCPU(
                view: SIMD4(Float(size.width), Float(size.height), Float(scale), Float(state.time)),
                hole: SIMD4(Float(state.center.x), Float(state.center.y), Float(state.radius),
                            Float(BlackHoleEase.smoothstep(0, 0.45, state.presence))),
                shape: SIMD4(Float(state.halfSize.width), Float(state.halfSize.height), Float(c.innerBoost), Float(c.innerWidth)),
                img: SIMD4(BlackHoleRenderer.diskShadowCenter.x, BlackHoleRenderer.diskShadowCenter.y,
                           BlackHoleRenderer.diskShadowRadius, Float(c.ringSpeed)),
                look: SIMD4(0, 0, Float(c.ringBrightness), Float(c.ringSoftness)),
                ring: SIMD4(1.0, 0.35, Float(c.ringSqueeze), Float(c.ringGamma)))
            renderer.drawOverlay(encoder: encoder, uniforms: &u)
        }
    }
}

// MARK: - Metal view

/// MTKView drawn manually from the animator's display link (one frame per tick, no own timer).
final class BlackHoleMetalView: MTKView {
    init(device: MTLDevice, opaque: Bool) {
        super.init(frame: .zero, device: device)
        isOpaque = opaque
        backgroundColor = .clear
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        colorPixelFormat = .bgra8Unorm
        isPaused = true
        enableSetNeedsDisplay = false
        isUserInteractionEnabled = false
        // Drawable size is set explicitly before every frame (see render): automatic resizing
        // missed frame changes made while the view was hidden.
        autoResizeDrawable = false
        contentScaleFactor = UIScreen.main.scale
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private lazy var queue = device?.makeCommandQueue()

    private var pending: ((MTLRenderCommandEncoder, CGSize, CGFloat) -> Void)?

    /// Renders one frame now. Goes through MTKView's own draw cycle: `currentDrawable` is only
    /// refreshed per `draw()`, outside of it every frame would go into the already presented drawable.
    func render(_ body: @escaping (MTLRenderCommandEncoder, CGSize, CGFloat) -> Void) {
        guard !isHidden, bounds.width > 0 else { return }
        let size = CGSize(width: (bounds.width * contentScaleFactor).rounded(), height: (bounds.height * contentScaleFactor).rounded())
        if drawableSize != size { drawableSize = size }
        pending = body
        draw()
        pending = nil
    }

    override func draw(_ rect: CGRect) {
        guard let body = pending, let queue, let pass = currentRenderPassDescriptor,
              let drawable = currentDrawable, let buffer = queue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        body(encoder, bounds.size, contentScaleFactor)
        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()
    }
}

// MARK: - Renderer

final class BlackHoleRenderer {
    /// Geometry of BlackHoleDisk.png (2000×1000): shadow center and radius in pixels.
    static let diskShadowCenter = SIMD2<Float>(1000, 451)
    static let diskShadowRadius: Float = 223

    let device: MTLDevice
    private let library: MTLLibrary
    private let bundle: Bundle
    private var backdropPipeline: MTLRenderPipelineState?
    private var overlayPipeline: MTLRenderPipelineState?
    private var meshPipeline: MTLRenderPipelineState?
    private var diskTexture: MTLTexture?
    private let lock = NSLock()
    private lazy var mipSampler: MTLSamplerState? = {
        let d = MTLSamplerDescriptor()
        d.minFilter = .linear; d.magFilter = .linear; d.mipFilter = .linear
        d.sAddressMode = .clampToZero; d.tAddressMode = .clampToZero
        return device.makeSamplerState(descriptor: d)
    }()

    init?(bundle: Bundle) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let library = try? device.makeDefaultLibrary(bundle: bundle) else { return nil }
        self.device = device
        self.library = library
        self.bundle = bundle
    }

    func prewarm() {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            _ = pipelines()
            _ = disk()
        }
    }

    private func pipelines() -> (MTLRenderPipelineState, MTLRenderPipelineState, MTLRenderPipelineState)? {
        lock.lock(); defer { lock.unlock() }
        if backdropPipeline == nil {
            backdropPipeline = make(vertex: "blackHoleScreenVertex", fragment: "blackHoleBackdropFragment", blending: false)
            overlayPipeline = make(vertex: "blackHoleOverlayVertex", fragment: "blackHoleOverlayFragment", blending: true)
            meshPipeline = make(vertex: "blackHoleMeshVertex", fragment: "blackHoleMeshFragment", blending: true)
        }
        guard let a = backdropPipeline, let b = overlayPipeline, let c = meshPipeline else { return nil }
        return (a, b, c)
    }

    private func disk() -> MTLTexture? {
        lock.lock(); defer { lock.unlock() }
        if diskTexture == nil, let url = bundle.url(forResource: "BlackHoleDisk", withExtension: "png") {
            diskTexture = try? MTKTextureLoader(device: device).newTexture(URL: url, options: [
                .generateMipmaps: true, .SRGB: false,
                .textureStorageMode: MTLStorageMode.private.rawValue,
                .textureUsage: MTLTextureUsage.shaderRead.rawValue,
            ])
        }
        return diskTexture
    }

    private func make(vertex: String, fragment: String, blending: Bool) -> MTLRenderPipelineState? {
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = library.makeFunction(name: vertex)
        d.fragmentFunction = library.makeFunction(name: fragment)
        let a = d.colorAttachments[0]!
        a.pixelFormat = .bgra8Unorm
        if blending {
            // Premultiplied alpha.
            a.isBlendingEnabled = true
            a.sourceRGBBlendFactor = .one; a.sourceAlphaBlendFactor = .one
            a.destinationRGBBlendFactor = .oneMinusSourceAlpha; a.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        }
        return try? device.makeRenderPipelineState(descriptor: d)
    }

    func drawBackdrop(encoder: MTLRenderCommandEncoder, uniforms: inout BackdropUniformsCPU, wallpaper: MTLTexture) {
        guard let pipeline = pipelines()?.0 else { return }
        var view = uniforms.view
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBytes(&view, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<BackdropUniformsCPU>.stride, index: 0)
        encoder.setFragmentTexture(wallpaper, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }

    func drawOverlay(encoder: MTLRenderCommandEncoder, uniforms: inout OverlayUniformsCPU) {
        guard let pipeline = pipelines()?.1, let disk = disk(), let sampler = mipSampler else { return }
        uniforms.look.x = Float(disk.width)
        uniforms.look.y = Float(disk.height)
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<OverlayUniformsCPU>.stride, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<OverlayUniformsCPU>.stride, index: 0)
        encoder.setFragmentTexture(disk, index: 0)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }

    func drawMesh(encoder: MTLRenderCommandEncoder, uniforms: inout MeshUniformsCPU, texture: MTLTexture, vertexCount: Int) {
        guard let pipeline = pipelines()?.2, let sampler = mipSampler else { return }
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<MeshUniformsCPU>.stride, index: 0)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertexCount)
    }

    /// Texture from a CGImage: redrawn into 8-bit premultiplied RGBA (snapshots come in formats
    /// MTKTextureLoader can't read), with mip levels for the blur near the horizon.
    static func makeTexture(device: MTLDevice, image: CGImage, mipmapped: Bool = true) -> MTLTexture? {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height,
                                                                  mipmapped: mipmapped)
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: pixels, bytesPerRow: width * 4)
        if mipmapped, let queue = device.makeCommandQueue(), let buffer = queue.makeCommandBuffer(),
           let blit = buffer.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: texture)
            blit.endEncoding()
            buffer.commit()
            buffer.waitUntilCompleted()
        }
        return texture
    }
}

/// CADisplayLink retains its target — the proxy breaks the cycle.
private final class DisplayLinkTarget: NSObject {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func fire() { action() }
}

// MARK: - Uniform layouts (match BlackHole.metal; all fields are float4)

struct BackdropUniformsCPU {
    var view, hole, shape, space: SIMD4<Float>
}

struct OverlayUniformsCPU {
    var view, hole, shape, img, look, ring: SIMD4<Float>
}

struct MeshUniformsCPU {
    var view, hole, flow, extra, fade, frame, grid: SIMD4<Float>
}
