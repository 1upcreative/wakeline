import simd

struct Particle {
    var p: V3, v: V3
    var color: V3
    var life: Float, maxLife: Float
    var size: Float, gravity: Float, drag: Float, stretch: Float
}

struct ParticleGPU {
    var pos: V4, vel: V4, color: V4
}

final class Particles {
    static let capacity = 9000
    private(set) var items: [Particle] = []
    init() { items.reserveCapacity(Particles.capacity) }

    func add(_ p: Particle) {
        if items.count < Particles.capacity { items.append(p) }
    }

    func clear() { items.removeAll(keepingCapacity: true) }

    func update(_ dt: Float) {
        var i = 0
        while i < items.count {
            items[i].life -= dt
            if items[i].life <= 0 {
                items.swapAt(i, items.count - 1)
                items.removeLast()
                continue
            }
            items[i].v.y -= items[i].gravity * dt
            items[i].v *= exp(-items[i].drag * dt)
            items[i].p += items[i].v * dt
            if items[i].p.y < 0.04 {
                items[i].p.y = 0.04
                items[i].v.y *= -0.42
                items[i].v.x *= 0.75
                items[i].v.z *= 0.75
            }
            i += 1
        }
    }

    func write(to out: UnsafeMutablePointer<ParticleGPU>) -> Int {
        for (i, q) in items.enumerated() {
            let k = q.life / q.maxLife
            out[i] = ParticleGPU(pos: V4(q.p, q.size * (0.35 + 0.65 * k)), vel: V4(q.v, q.stretch),
                                 color: V4(q.color * k * k, 1))
        }
        return items.count
    }
}
