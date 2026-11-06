import simd

/// The camera looks straight down so the whole maze fills the screen. It only
/// leaves that framing to drop in on a crash, then rises back out.
final class Director {
    var eye = Arena.center + V3(0, 260, 12), target = Arena.center, up = V3(0, 0, -1)
    var fov: Float = 0.62
    private var fresh = true

    func reset() { fresh = true }

    func update(_ dt: Float, world: World, aspect: Float) {
        let race = world.race
        // A hair of tilt keeps the walls reading as 3D instead of flat lines.
        let tilt: Float = 0.045
        let h = max(Arena.depth * 0.5, Arena.width * 0.5 / aspect) / tan(0.5 * fov) * 1.015
        var wantEye = Arena.center + V3(0, h, h * tilt)
        var wantTarget = Arena.center
        var rate: Float = 1.7

        if race.phase == .crash, race.phaseTime < 3.1, let c = race.crash {
            let spot = V3(c.pos.x, 0, c.pos.y)
            let low = h * 0.34
            wantEye = spot + V3(0, low, low * 0.2)
            wantTarget = spot
            rate = 3.2
        }
        if fresh {
            eye = wantEye; target = wantTarget
            fresh = false
        } else {
            eye += (wantEye - eye) * damp(rate, dt)
            target += (wantTarget - target) * damp(rate, dt)
        }
        up = V3(0, 0, -1)
    }
}
