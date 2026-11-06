import AppKit
import QuartzCore

/// A layer-backed view that owns one display's world and renderer.
/// Shared by the screensaver and the preview app so they cannot drift apart.
final class WakelineHostView: NSView {
    private let metalLayer = CAMetalLayer()
    private var renderer: Renderer?
    private(set) var world: World
    private var last = CACurrentMediaTime()
    private var slowFrames = 0, fastFrames = 0
    var paused = false

    init(frame: NSRect, seed: UInt64) {
        world = World(seed: seed)
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        guard let gpu = GPU.shared else { return }
        let r: Renderer
        do { r = try Renderer(gpu: gpu) } catch {
            NSLog("Wakeline renderer setup failed: %@", String(describing: error))
            return
        }
        renderer = r
        metalLayer.device = gpu.device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.maximumDrawableCount = 3
        metalLayer.isOpaque = true
    }

    @available(*, unavailable) required init?(coder: NSCoder) { nil }

    override func makeBackingLayer() -> CALayer { metalLayer }
    var ready: Bool { renderer != nil }

    private func syncDrawableSize() -> (Int, Int) {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        metalLayer.contentsScale = scale
        let w = max(Int(bounds.width * scale), 1), h = max(Int(bounds.height * scale), 1)
        if Int(metalLayer.drawableSize.width) != w || Int(metalLayer.drawableSize.height) != h {
            metalLayer.drawableSize = CGSize(width: w, height: h)
        }
        return (w, h)
    }

    func tick() {
        guard !paused, let renderer, bounds.width > 1, bounds.height > 1 else { return }
        let now = CACurrentMediaTime()
        let dt = Float(now - last)
        last = now
        adapt(renderer, dt)
        let size = syncDrawableSize()
        world.tick(dt, aspect: Float(size.0) / Float(size.1))
        autoreleasepool {
            guard let drawable = metalLayer.nextDrawable() else { return }
            renderer.draw(world, drawable: drawable, size: size)
        }
    }

    /// Protects smoothness on smaller Macs: shed resolution before shedding frames.
    private func adapt(_ r: Renderer, _ dt: Float) {
        guard dt < 0.25 else { return }
        if dt > 1 / 45 { slowFrames += 1; fastFrames = 0 } else { fastFrames += 1; slowFrames = max(slowFrames - 1, 0) }
        if slowFrames > 90, r.renderScale > 0.5 {
            r.renderScale = max(r.renderScale - 0.1, 0.5)
            slowFrames = 0
        } else if fastFrames > 1800, r.renderScale < 1 {
            r.renderScale = min(r.renderScale + 0.1, 1)
            fastFrames = 0
        }
    }

    func resume() { last = CACurrentMediaTime(); paused = false }
    func nextRace() { world.restart() }
}
