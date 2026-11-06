import Foundation
import Metal
import QuartzCore
import simd

private struct FrameU {
    var vp: M4, ivp: M4
    var eye: V4, lightA: V4, lightB: V4, colA: V4, colB: V4, shock: V4, misc: V4, flash: V4, view: V4, shockColor: V4
}
private struct InstU { var model: M4; var color: V4; var params: V4 }
private struct WallU { var color: V4; var params: V4 }
private struct CompU { var a: V4; var b: V4 }
private struct WallV { var a: V4; var b: V4 }

private let hdrFormat = MTLPixelFormat.rgba16Float
private let depthFormat = MTLPixelFormat.depth32Float
private let outFormat = MTLPixelFormat.bgra8Unorm
private let msaa = 4
private let bloomLevels = 6
private let framesInFlight = 3
private let glowW = Arena.cols * 2, glowH = Arena.rows * 2

/// Draws a World. One instance per display.
final class Renderer {
    private struct PassSet { let sky, floor, mesh, wall, part: MTLRenderPipelineState }
    private let gpu: GPU
    private var device: MTLDevice { gpu.device }
    private let main: PassSet, mirror: PassSet
    private let down, up, composite: MTLRenderPipelineState
    private let dsWrite, dsRead, dsOff: MTLDepthStencilState
    private let skyTex: MTLTexture
    private let glowTex: MTLTexture
    private var glowPixels: [UInt8]
    private var wallBufs: [MTLBuffer] = [], partBufs: [MTLBuffer] = []
    private let borderBuf: MTLBuffer
    private let borderCount: Int
    private let pylonInstances: [InstU]
    private let flight = DispatchSemaphore(value: framesInFlight)
    private var frameIndex = 0

    private var targetSize = (0, 0)
    private var msColor, msDepth, hdr, reflColor, reflDepth, bloom: MTLTexture?
    private var bloomViews: [MTLTexture] = []
    private var readback: MTLTexture?

    /// Fraction of native resolution. Lowered by the host if frames run long.
    var renderScale: Float = 1
    var maxRenderWidth = 3200
    private(set) var lastGPUTime: Double = 0

    init(gpu: GPU) throws {
        self.gpu = gpu
        let device = gpu.device
        func pipe(_ vs: String, _ fs: String, format: MTLPixelFormat, samples: Int, depth: Bool,
                  blend: ((MTLRenderPipelineColorAttachmentDescriptor) -> Void)? = nil) throws -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = try gpu.function(vs)
            d.fragmentFunction = try gpu.function(fs)
            d.rasterSampleCount = samples
            d.colorAttachments[0].pixelFormat = format
            if depth { d.depthAttachmentPixelFormat = depthFormat }
            blend?(d.colorAttachments[0])
            return try device.makeRenderPipelineState(descriptor: d)
        }
        let additive: (MTLRenderPipelineColorAttachmentDescriptor) -> Void = {
            $0.isBlendingEnabled = true
            $0.sourceRGBBlendFactor = .one; $0.destinationRGBBlendFactor = .one
            $0.sourceAlphaBlendFactor = .zero; $0.destinationAlphaBlendFactor = .one
        }
        let premultiplied: (MTLRenderPipelineColorAttachmentDescriptor) -> Void = {
            $0.isBlendingEnabled = true
            $0.sourceRGBBlendFactor = .one; $0.destinationRGBBlendFactor = .oneMinusSourceAlpha
            $0.sourceAlphaBlendFactor = .one; $0.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        }
        func set(_ s: Int) throws -> PassSet {
            PassSet(sky: try pipe("skyVS", "skyFS", format: hdrFormat, samples: s, depth: true),
                    floor: try pipe("floorVS", "floorFS", format: hdrFormat, samples: s, depth: true),
                    mesh: try pipe("meshVS", "meshFS", format: hdrFormat, samples: s, depth: true),
                    wall: try pipe("wallVS", "wallFS", format: hdrFormat, samples: s, depth: true, blend: premultiplied),
                    part: try pipe("partVS", "partFS", format: hdrFormat, samples: s, depth: true, blend: additive))
        }
        main = try set(msaa)
        mirror = try set(1)
        down = try pipe("fsVS", "bloomDownFS", format: hdrFormat, samples: 1, depth: false)
        up = try pipe("fsVS", "bloomUpFS", format: hdrFormat, samples: 1, depth: false, blend: additive)
        composite = try pipe("fsVS", "compositeFS", format: outFormat, samples: 1, depth: false)

        func ds(_ write: Bool, _ cmp: MTLCompareFunction) -> MTLDepthStencilState {
            let d = MTLDepthStencilDescriptor()
            d.isDepthWriteEnabled = write
            d.depthCompareFunction = cmp
            return device.makeDepthStencilState(descriptor: d)!
        }
        dsWrite = ds(true, .lessEqual); dsRead = ds(false, .lessEqual); dsOff = ds(false, .always)

        // Sky is baked once, then doubles as the reflection map for the bikes.
        let skyD = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: hdrFormat, width: 3072, height: 1536, mipmapped: true)
        skyD.usage = [.renderTarget, .shaderRead]
        skyD.storageMode = .private
        skyTex = device.makeTexture(descriptor: skyD)!
        let bake = try pipe("fsVS", "skyBakeFS", format: hdrFormat, samples: 1, depth: false)
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = skyTex
        rp.colorAttachments[0].loadAction = .dontCare
        rp.colorAttachments[0].storeAction = .store
        let cb = gpu.queue.makeCommandBuffer()!
        let enc = cb.makeRenderCommandEncoder(descriptor: rp)!
        enc.setRenderPipelineState(bake)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
        let blit = cb.makeBlitCommandEncoder()!
        blit.generateMipmaps(for: skyTex)
        blit.endEncoding()
        cb.commit()

        let glowD = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: glowW, height: glowH, mipmapped: true)
        glowD.usage = [.shaderRead]
        glowD.storageMode = .shared
        glowTex = device.makeTexture(descriptor: glowD)!
        glowPixels = .init(repeating: 0, count: glowW * glowH * 4)

        let maxSegments = Arena.cols * Arena.rows * 2 + 8
        for _ in 0..<framesInFlight {
            wallBufs.append(device.makeBuffer(length: maxSegments * 18 * MemoryLayout<WallV>.stride, options: .storageModeShared)!)
            partBufs.append(device.makeBuffer(length: Particles.capacity * MemoryLayout<ParticleGPU>.stride, options: .storageModeShared)!)
        }
        let W = Arena.width, D = Arena.depth
        var border: [WallV] = []
        Renderer.appendPath([V2(0, 0), V2(W, 0), V2(W, D), V2(0, D), V2(0, 0)], end: .infinity, height: 0.7, into: &border)
        borderCount = border.count
        borderBuf = device.makeBuffer(bytes: border, length: border.count * MemoryLayout<WallV>.stride, options: .storageModeShared)!

        var pyl: [InstU] = []
        let step: Float = 36, margin: Float = 15
        func addPylon(_ x: Float, _ z: Float, _ i: Int) {
            let h = 1 + 0.3 * sin(Float(i) * 2.4) + 0.25 * sin(Float(i) * 0.71)
            var m = Mat.translate(V3(x, 0, z))
            m.columns.1 *= h
            pyl.append(InstU(model: m, color: V4(0.3, 0.42, 1.0, 0), params: V4(1000, 1.6, 0, 0)))
        }
        var i = 0
        var x = -margin
        while x <= W + margin { addPylon(x, -margin, i); addPylon(x, D + margin, i + 7); x += step; i += 1 }
        var z = step - margin
        while z < D + margin { addPylon(-margin, z, i); addPylon(W + margin, z, i + 7); z += step; i += 1 }
        pylonInstances = pyl
    }

    private func makeTargets(_ w: Int, _ h: Int) {
        guard (w, h) != targetSize else { return }
        targetSize = (w, h)
        let memoryless = device.supportsFamily(.apple7)
        func tex(_ f: MTLPixelFormat, _ w: Int, _ h: Int, samples: Int = 1, mips: Int = 1,
                 usage: MTLTextureUsage, transient: Bool = false) -> MTLTexture {
            let d = MTLTextureDescriptor()
            d.pixelFormat = f; d.width = w; d.height = h
            d.textureType = samples > 1 ? .type2DMultisample : .type2D
            d.sampleCount = samples; d.mipmapLevelCount = mips; d.usage = usage
            d.storageMode = transient && memoryless ? .memoryless : .private
            return device.makeTexture(descriptor: d)!
        }
        msColor = tex(hdrFormat, w, h, samples: msaa, usage: .renderTarget, transient: true)
        msDepth = tex(depthFormat, w, h, samples: msaa, usage: .renderTarget, transient: true)
        hdr = tex(hdrFormat, w, h, usage: [.renderTarget, .shaderRead])
        let rw = max(w / 2, 4), rh = max(h / 2, 4)
        let reflMips = Int(log2(Float(min(rw, rh)))) - 1
        reflColor = tex(hdrFormat, rw, rh, mips: max(reflMips, 1), usage: [.renderTarget, .shaderRead])
        reflDepth = tex(depthFormat, rw, rh, usage: .renderTarget, transient: true)
        let levels = min(bloomLevels, max(Int(log2(Float(min(rw, rh)))) - 2, 2))
        bloom = tex(hdrFormat, rw, rh, mips: levels, usage: [.renderTarget, .shaderRead])
        bloomViews = (0..<levels).map { bloom!.makeTextureView(pixelFormat: hdrFormat, textureType: .type2D,
                                                               levels: $0..<($0 + 1), slices: 0..<1)! }
    }

    private func internalSize(_ w: Int, _ h: Int) -> (Int, Int) {
        let cap = Float(maxRenderWidth) / Float(max(w, 1))
        let s = min(min(renderScale, cap), 1)
        return (max(Int(Float(w) * s) & ~1, 16), max(Int(Float(h) * s) & ~1, 16))
    }

    // MARK: - Dynamic geometry

    private static func appendPath(_ pts: [V2], end: Float, height: Float, startU: Float = 0, into out: inout [WallV]) {
        var u = startU
        for i in 0..<(pts.count - 1) {
            appendSegment(pts[i], pts[i + 1], u, height, into: &out)
            u += simd_distance(pts[i], pts[i + 1])
        }
    }

    private static func appendSegment(_ a0: V2, _ b0: V2, _ u: Float, _ height: Float, into out: inout [WallV]) {
        let len = simd_distance(a0, b0)
        guard len > 1e-3 else { return }
        let t: Float = 0.3
        let d = (b0 - a0) / len
        let n = V2(-d.y, d.x) * t
        let a = a0 - d * t, b = b0 + d * t
        let u1 = u + len
        func v(_ p: V2, _ y: Float, _ uu: Float, _ h: Float, _ top: Float, _ across: Float = 0) -> WallV {
            WallV(a: V4(p.x, y, p.y, uu), b: V4(h, top, across, 0))
        }
        func quad(_ q0: WallV, _ q1: WallV, _ q2: WallV, _ q3: WallV) {
            out.append(q0); out.append(q1); out.append(q2); out.append(q0); out.append(q2); out.append(q3)
        }
        quad(v(a + n, 0, u, 0, 0), v(b + n, 0, u1, 0, 0), v(b + n, height, u1, 1, 0), v(a + n, height, u, 1, 0))
        quad(v(a - n, 0, u, 0, 0), v(b - n, 0, u1, 0, 0), v(b - n, height, u1, 1, 0), v(a - n, height, u, 1, 0))
        quad(v(a + n, height, u, 1, 1, 1), v(b + n, height, u1, 1, 1, 1), v(b - n, height, u1, 1, 1, -1), v(a - n, height, u, 1, 1, -1))
    }

    private func visiblePath(_ r: Rider) -> [V2] {
        let end = max(r.tailS, 0)
        var pts: [V2] = []
        pts.reserveCapacity(r.corners.count + 1)
        for i in 0..<r.corners.count where r.cornerS[i] < end { pts.append(r.corners[i]) }
        pts.append(r.point(end))
        return pts
    }

    private func updateGlow(_ world: World) {
        glowPixels.withUnsafeMutableBufferPointer { px in
            px.initialize(repeating: 0)
            for r in world.race.riders {
                let c = Team.colors[r.team]
                let bytes = (UInt8(c.x * 255), UInt8(c.y * 255), UInt8(c.z * 255))
                let limit = min(max(r.tailS, 0), world.race.front[r.team])
                var q: Float = 0
                while q < limit {
                    let p = r.point(q)
                    // The bias keeps lattice lines off a texel boundary, where rounding flips sides.
                    let x = Int(p.x / Arena.width * Float(glowW) + 0.25), y = Int(p.y / Arena.depth * Float(glowH) + 0.25)
                    if x >= 0, y >= 0, x < glowW, y < glowH {
                        let o = (y * glowW + x) * 4
                        px[o] = max(px[o], bytes.0); px[o + 1] = max(px[o + 1], bytes.1); px[o + 2] = max(px[o + 2], bytes.2)
                        px[o + 3] = 255
                    }
                    q += 1.5
                }
            }
        }
        glowPixels.withUnsafeBytes {
            glowTex.replace(region: MTLRegionMake2D(0, 0, glowW, glowH), mipmapLevel: 0,
                            withBytes: $0.baseAddress!, bytesPerRow: glowW * 4)
        }
    }

    // MARK: - Frame

    /// Renders to a drawable when given, otherwise into `readback` for capture.
    func draw(_ world: World, drawable: CAMetalDrawable?, size: (Int, Int), capture: UnsafeMutableRawPointer? = nil) {
        flight.wait()
        let (w, h) = internalSize(size.0, size.1)
        makeTargets(w, h)
        guard let cmd = gpu.queue.makeCommandBuffer() else { flight.signal(); return }
        frameIndex = (frameIndex + 1) % framesInFlight
        updateGlow(world)

        var verts: [WallV] = []
        verts.reserveCapacity(2048)
        var ranges: [(start: Int, count: Int, u: WallU)] = []
        for r in world.race.riders {
            let start = verts.count
            Renderer.appendPath(visiblePath(r), end: r.tailS, height: Arena.wallHeight, into: &verts)
            let front = world.race.front[r.team]
            let u = WallU(color: V4(Team.colors[r.team], 1), params: V4(r.tailS, front.isFinite ? front : 1e7, Arena.wallHeight, 1))
            ranges.append((start, verts.count - start, u))
        }
        let wallBuf = wallBufs[frameIndex]
        verts.withUnsafeBytes { wallBuf.contents().copyMemory(from: $0.baseAddress!, byteCount: min($0.count, wallBuf.length)) }
        let partBuf = partBufs[frameIndex]
        let partCount = world.particles.write(to: partBuf.contents().bindMemory(to: ParticleGPU.self, capacity: Particles.capacity))

        let bikes = bikeInstances(world)
        let cam = world.director
        let aspect = Float(size.0) / Float(size.1)
        let proj = Mat.perspective(fovY: cam.fov, aspect: aspect, near: 0.25, far: 12000)
        let view = Mat.lookAt(eye: cam.eye, target: cam.target, up: cam.up)
        let vp = proj * view
        var f = frameUniforms(world, vp: vp, eye: cam.eye, w: Float(w), h: Float(h), reflection: 0)

        // Mirror pass: the wet floor reflects the real scene, not a cube-map guess.
        var mf = f
        var flip = matrix_identity_float4x4
        flip.columns.1.y = -1
        mf.vp = vp * flip
        mf.ivp = mf.vp.inverse
        mf.eye = V4(cam.eye.x, -cam.eye.y, cam.eye.z, f.eye.w)
        mf.view = V4(Float(reflColor!.width), Float(reflColor!.height), f.view.z, f.view.w)
        mf.misc.w = 1
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = reflColor
        rp.colorAttachments[0].loadAction = .clear
        rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        rp.colorAttachments[0].storeAction = .store
        rp.depthAttachment.texture = reflDepth
        rp.depthAttachment.loadAction = .clear
        rp.depthAttachment.clearDepth = 1
        rp.depthAttachment.storeAction = .dontCare
        let re = cmd.makeRenderCommandEncoder(descriptor: rp)!
        encodeScene(re, set: mirror, frame: &mf, bikes: bikes, wallBuf: wallBuf, ranges: ranges,
                    partBuf: partBuf, partCount: partCount, drawFloor: false, front: .clockwise)
        re.endEncoding()
        let blit = cmd.makeBlitCommandEncoder()!
        blit.generateMipmaps(for: reflColor!)
        blit.generateMipmaps(for: glowTex)
        blit.endEncoding()

        let mp = MTLRenderPassDescriptor()
        mp.colorAttachments[0].texture = msColor
        mp.colorAttachments[0].resolveTexture = hdr
        mp.colorAttachments[0].loadAction = .dontCare
        mp.colorAttachments[0].storeAction = .multisampleResolve
        mp.depthAttachment.texture = msDepth
        mp.depthAttachment.loadAction = .clear
        mp.depthAttachment.clearDepth = 1
        mp.depthAttachment.storeAction = .dontCare
        let me = cmd.makeRenderCommandEncoder(descriptor: mp)!
        encodeScene(me, set: main, frame: &f, bikes: bikes, wallBuf: wallBuf, ranges: ranges,
                    partBuf: partBuf, partCount: partCount, drawFloor: true, front: .counterClockwise)
        me.endEncoding()

        encodeBloom(cmd)

        var outTex: MTLTexture? = drawable?.texture
        if outTex == nil {
            if readback == nil || readback!.width != size.0 || readback!.height != size.1 {
                let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: outFormat, width: size.0, height: size.1, mipmapped: false)
                d.usage = [.renderTarget]
                d.storageMode = .shared
                readback = device.makeTexture(descriptor: d)
            }
            outTex = readback
        }
        let op = MTLRenderPassDescriptor()
        op.colorAttachments[0].texture = outTex
        op.colorAttachments[0].loadAction = .dontCare
        op.colorAttachments[0].storeAction = .store
        let oe = cmd.makeRenderCommandEncoder(descriptor: op)!
        oe.setRenderPipelineState(composite)
        oe.setFragmentTexture(hdr, index: 0)
        oe.setFragmentTexture(bloomViews[0], index: 1)
        let impact = world.impactGlow
        var comp = CompU(a: V4(1.1 + impact * 0.5, world.fade, world.time, 0.003 + impact * 0.03),
                         b: V4(0.012, 0, 0.6, 0.055))
        oe.setFragmentBytes(&comp, length: MemoryLayout<CompU>.stride, index: 0)
        oe.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        oe.endEncoding()

        // Held strongly: libdispatch aborts if a semaphore is released mid-count,
        // and the host may drop this renderer with frames still on the GPU.
        let flight = self.flight
        cmd.addCompletedHandler { [weak self] c in
            self?.lastGPUTime = c.gpuEndTime - c.gpuStartTime
            flight.signal()
        }
        if let drawable { cmd.present(drawable) }
        cmd.commit()
        if let capture {
            cmd.waitUntilCompleted()
            outTex?.getBytes(capture, bytesPerRow: size.0 * 4,
                             from: MTLRegionMake2D(0, 0, size.0, size.1), mipmapLevel: 0)
        }
    }

    private func frameUniforms(_ world: World, vp: M4, eye: V3, w: Float, h: Float, reflection: Float) -> FrameU {
        let race = world.race
        func light(_ r: Rider) -> V4 {
            let c = r.point(r.s - Arena.bikeLength / 2)
            let on = r.alive && race.phase != .done ? smooth(0, 5, r.reveal) : 0
            return V4(c.x, 1.3, c.y, 30 * on)
        }
        return FrameU(vp: vp, ivp: vp.inverse, eye: V4(eye, world.time),
                      lightA: light(race.riders[0]), lightB: light(race.riders[1]),
                      colA: V4(Team.colors[0], 0), colB: V4(Team.colors[1], 0), shock: world.shock,
                      misc: V4(Arena.width, Arena.depth, Arena.pitch, reflection),
                      flash: V4(world.flashPos, world.flash * 420), view: V4(w, h, world.impactGlow, world.fade),
                      shockColor: V4(world.shockColor, 0))
    }

    private func bikeInstances(_ world: World) -> [(part: Mesh.Part, inst: InstU)] {
        var out: [(Mesh.Part, InstU)] = []
        for r in world.race.riders where r.alive && r.reveal > 0.01 {
            let nose = r.point(r.s), tail = r.point(r.tailS)
            let mid = (nose + tail) * 0.5
            let f = V3(cos(r.heading), 0, sin(r.heading))
            let m = Mat.heading(forward: f, position: V3(mid.x, 0, mid.y)) * Mat.rotateZ(r.lean) * Mat.scale(Arena.bikeScale)
            let color = V4(Team.colors[r.team], 0)
            let params = V4(r.reveal, 7, 0, 0)
            for p in world.gpuParts {
                var model = m
                if p.pivot != .zero {
                    model = m * Mat.translate(p.pivot) * Mat.rotateX(-r.wheelAngle) * Mat.translate(-p.pivot)
                }
                out.append((p, InstU(model: model, color: color, params: params)))
            }
        }
        return out
    }

    private func encodeScene(_ e: MTLRenderCommandEncoder, set: PassSet, frame f: inout FrameU,
                             bikes: [(part: Mesh.Part, inst: InstU)], wallBuf: MTLBuffer,
                             ranges: [(start: Int, count: Int, u: WallU)], partBuf: MTLBuffer, partCount: Int,
                             drawFloor: Bool, front: MTLWinding) {
        let fSize = MemoryLayout<FrameU>.stride
        e.setFrontFacing(front)

        // The overhead camera sees the mirror straight on, where a reflected sky
        // only reads as a smear: the floor reflects the racers and nothing else.
        if drawFloor {
            e.setDepthStencilState(dsOff)
            e.setRenderPipelineState(set.sky)
            e.setVertexBytes(&f, length: fSize, index: 0)
            e.setFragmentTexture(skyTex, index: 0)
            e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }

        e.setDepthStencilState(dsWrite)
        if drawFloor {
            e.setRenderPipelineState(set.floor)
            e.setFragmentBytes(&f, length: fSize, index: 0)
            e.setFragmentTexture(reflColor, index: 0)
            e.setFragmentTexture(glowTex, index: 1)
            e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        }

        e.setRenderPipelineState(set.mesh)
        e.setCullMode(.back)
        e.setVertexBytes(&f, length: fSize, index: 1)
        e.setFragmentBytes(&f, length: fSize, index: 0)
        e.setFragmentTexture(skyTex, index: 0)
        for var b in bikes {
            e.setVertexBuffer(b.part.vertices, offset: 0, index: 0)
            e.setVertexBytes(&b.inst, length: MemoryLayout<InstU>.stride, index: 2)
            e.drawIndexedPrimitives(type: .triangle, indexCount: b.part.indexCount, indexType: .uint32,
                                    indexBuffer: b.part.indices, indexBufferOffset: 0)
        }
        if let p = gpu.pylon.part("body") {
            e.setVertexBuffer(p.vertices, offset: 0, index: 0)
            pylonInstances.withUnsafeBytes { e.setVertexBytes($0.baseAddress!, length: $0.count, index: 2) }
            e.drawIndexedPrimitives(type: .triangle, indexCount: p.indexCount, indexType: .uint32, indexBuffer: p.indices,
                                    indexBufferOffset: 0, instanceCount: pylonInstances.count)
        }
        e.setCullMode(.none)

        e.setRenderPipelineState(set.wall)
        e.setDepthStencilState(dsRead)
        e.setVertexBytes(&f, length: fSize, index: 1)
        e.setFragmentBytes(&f, length: fSize, index: 0)
        var borderU = WallU(color: V4(0.3, 0.42, 1.0, 1), params: V4(1e7, 1e7, 0.7, 0.45))
        e.setVertexBuffer(borderBuf, offset: 0, index: 0)
        e.setFragmentBytes(&borderU, length: MemoryLayout<WallU>.stride, index: 1)
        e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: borderCount)
        e.setVertexBuffer(wallBuf, offset: 0, index: 0)
        for var r in ranges where r.count > 0 {
            e.setFragmentBytes(&r.u, length: MemoryLayout<WallU>.stride, index: 1)
            e.drawPrimitives(type: .triangle, vertexStart: r.start, vertexCount: r.count)
        }

        if partCount > 0 {
            e.setRenderPipelineState(set.part)
            e.setVertexBuffer(partBuf, offset: 0, index: 0)
            e.setVertexBytes(&f, length: fSize, index: 1)
            e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: partCount)
        }
    }

    private func encodeBloom(_ cmd: MTLCommandBuffer) {
        func pass(_ target: MTLTexture, load: MTLLoadAction, pipeline: MTLRenderPipelineState, source: MTLTexture) {
            let d = MTLRenderPassDescriptor()
            d.colorAttachments[0].texture = target
            d.colorAttachments[0].loadAction = load
            d.colorAttachments[0].storeAction = .store
            let e = cmd.makeRenderCommandEncoder(descriptor: d)!
            e.setRenderPipelineState(pipeline)
            e.setFragmentTexture(source, index: 0)
            var px = V2(1 / Float(source.width), 1 / Float(source.height))
            e.setFragmentBytes(&px, length: 8, index: 0)
            e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            e.endEncoding()
        }
        pass(bloomViews[0], load: .dontCare, pipeline: down, source: hdr!)
        for i in 1..<bloomViews.count {
            pass(bloomViews[i], load: .dontCare, pipeline: down, source: bloomViews[i - 1])
        }
        for i in stride(from: bloomViews.count - 1, to: 0, by: -1) {
            pass(bloomViews[i - 1], load: .load, pipeline: up, source: bloomViews[i])
        }
    }
}

extension World {
    /// Runner parts in draw order.
    var gpuParts: [Mesh.Part] { GPU.shared?.runner.parts ?? [] }
}
