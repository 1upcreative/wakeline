import Foundation
import simd

enum Team {
    static let colors = [V3(0.04, 1.0, 0.32), V3(0.06, 0.38, 1.0)]
}

/// Everything that moves: the race, its effects and the camera.
final class World {
    var race: Race
    let director = Director()
    let particles = Particles()
    var time: Float = 0
    var rng: SplitMix
    var flash: Float = 0
    var flashPos = V3.zero
    var shock = V4.zero
    var shockColor = V3.zero
    var impactGlow: Float = 0
    var racesRun = 0
    /// Seconds a new race waits in the dark before the riders appear.
    private var blackout: Float = 0.4

    init(seed: UInt64) {
        rng = SplitMix(state: seed)
        race = Race(seed: rng.next())
    }

    var fade: Float {
        if blackout > 0 { return 0 }
        switch race.phase {
        case .intro: return smooth(0, 1.0, race.phaseTime)
        case .outro: return 1 - smooth(Race.outroTime - 0.75, Race.outroTime - 0.05, race.phaseTime)
        case .done: return 0
        default: return 1
        }
    }

    func tick(_ rawDt: Float, aspect: Float) {
        let dt = min(rawDt, 1 / 15)
        // Wrapped so shader timing keeps its precision over days of uptime.
        time = (time + dt).truncatingRemainder(dividingBy: 3600)
        if blackout > 0 { blackout -= dt; return }
        race.tick(dt)
        let simDt = dt * race.timeScale
        for e in race.events { handle(e) }
        race.events.removeAll(keepingCapacity: true)
        emitContinuous(dt, simDt)
        particles.update(simDt)
        flash *= exp(-5 * dt)
        impactGlow *= exp(-1.1 * dt)
        if shock.w > 0.001 {
            shock.z += (150 / (1 + shock.z * 0.018)) * simDt
            shock.w *= exp(-2.4 * simDt)
        }
        director.update(dt, world: self, aspect: aspect)
        if race.phase == .done { restart() }
    }

    func restart() {
        race = Race(seed: rng.next())
        racesRun += 1
        particles.clear()
        director.reset()
        shock = .zero
        flash = 0
        blackout = 0.5
    }

    private func handle(_ e: Race.Event) {
        switch e {
        case .turn(let team, let p):
            sparks(at: V3(p.x, 0.15, p.y), color: Team.colors[team], count: 18, speed: 9, up: 3)
        case .crash(let c):
            explode(c)
        default:
            break
        }
    }

    private func sparks(at p: V3, color: V3, count: Int, speed: Float, up: Float) {
        for _ in 0..<count {
            let a = Float.random(in: 0...(2 * .pi), using: &rng)
            let s = Float.random(in: 0.2...1, using: &rng) * speed
            let v = V3(cos(a) * s, Float.random(in: 0...1, using: &rng) * up, sin(a) * s)
            particles.add(Particle(p: p, v: v, color: color * 5, life: 0.5, maxLife: Float.random(in: 0.4...0.9, using: &rng),
                                   size: 0.05, gravity: 16, drag: 1.2, stretch: 0.02))
        }
    }

    private func explode(_ c: Crash) {
        let p = V3(c.pos.x, 1, c.pos.y)
        let own = Team.colors[c.loser]
        let hit = c.hitTeam >= 0 ? Team.colors[c.hitTeam] : V3(1, 1, 1)
        flash = 1
        flashPos = p + V3(0, 6, 0)
        impactGlow = 1
        shock = V4(c.pos.x, c.pos.y, 0, 1)
        shockColor = own * 2.2 + V3(0.08, 0.08, 0.08)
        for i in 0..<2400 {
            let dirn = simd_normalize(V3(Float.random(in: -1...1, using: &rng), Float.random(in: -0.1...1, using: &rng),
                                         Float.random(in: -1...1, using: &rng)) + V3(0.001, 0.001, 0.001))
            let s = pow(Float.random(in: 0...1, using: &rng), 2.2) * 95 + 4
            let tint = i % 3 == 0 ? hit : own
            let hot = Float.random(in: 2...14, using: &rng)
            let life = Float.random(in: 0.7...4.2, using: &rng)
            particles.add(Particle(p: p + dirn * 0.5, v: dirn * s, color: mixV(tint, V3(1, 1, 1), 0.25) * hot, life: life, maxLife: life,
                                   size: Float.random(in: 0.03...0.11, using: &rng), gravity: 11, drag: 1.0, stretch: 0.025))
        }
        // Heavier fragments of the bike tumble out and skid across the floor.
        for _ in 0..<420 {
            let dirn = simd_normalize(V3(Float.random(in: -1...1, using: &rng), Float.random(in: 0...1.2, using: &rng),
                                         Float.random(in: -1...1, using: &rng)) + V3(c.heading.x, 0, c.heading.y) * -0.4)
            let life = Float.random(in: 1.5...5, using: &rng)
            particles.add(Particle(p: p, v: dirn * Float.random(in: 5...38, using: &rng), color: own * Float.random(in: 2...6, using: &rng),
                                   life: life, maxLife: life, size: Float.random(in: 0.14...0.42, using: &rng), gravity: 22, drag: 0.5, stretch: 0))
        }
    }

    private func mixV(_ a: V3, _ b: V3, _ t: Float) -> V3 { a + (b - a) * t }

    private func emitContinuous(_ dt: Float, _ simDt: Float) {
        for r in race.riders where r.alive && r.reveal > 4 {
            let tail = r.point(r.tailS)
            // Motes shed from the wall's birth point.
            let count = Int(simDt * 70 + Float.random(in: 0...1, using: &rng))
            for _ in 0..<count {
                let life = Float.random(in: 0.35...1.1, using: &rng)
                let p = V3(tail.x, Float.random(in: 0.1...Arena.wallHeight, using: &rng), tail.y)
                let v = V3(Float.random(in: -1...1, using: &rng), Float.random(in: 0...2, using: &rng), Float.random(in: -1...1, using: &rng))
                particles.add(Particle(p: p, v: v, color: Team.colors[r.team] * 3, life: life, maxLife: life,
                                       size: 0.05, gravity: 0, drag: 1.5, stretch: 0.01))
            }
            if r.doomed { // the tell: an overloaded reactor spitting sparks
                let c = r.point(r.s - Arena.bikeLength / 2)
                sparks(at: V3(c.x, 0.7, c.y), color: V3(1, 0.75, 0.3), count: 3, speed: 12, up: 8)
            }
        }
        // Wall dissolve: fragments lift off where the front is eating the trail.
        for team in 0..<2 where race.front[team].isFinite && race.front[team] > 0 {
            let r = race.riders[team]
            let q = race.front[team]
            let count = Int(dt * 1300)
            for _ in 0..<count {
                let at = r.point(q + Float.random(in: 0...16, using: &rng))
                let life = Float.random(in: 0.5...1.7, using: &rng)
                let p = V3(at.x, Float.random(in: 0...Arena.wallHeight, using: &rng), at.y)
                let v = V3(Float.random(in: -2...2, using: &rng), Float.random(in: 2...11, using: &rng), Float.random(in: -2...2, using: &rng))
                particles.add(Particle(p: p, v: v, color: Team.colors[team] * Float.random(in: 2...7, using: &rng), life: life, maxLife: life,
                                       size: Float.random(in: 0.05...0.2, using: &rng), gravity: -1.5, drag: 0.6, stretch: 0))
            }
        }
    }
}
