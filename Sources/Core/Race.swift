import simd

/// Seedable generator so any race can be replayed in tests.
struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// The arena is a lattice: riders only travel its lines, which is what makes
/// the trails read as a maze with even corridors instead of scribble.
enum Arena {
    static let cols = 48, rows = 27
    static let pitch: Float = 6
    static let width = Float(cols) * pitch, depth = Float(rows) * pitch
    static let bikeScale: Float = 2.1
    static let bikeLength: Float = 10.5
    static let wallHeight: Float = 3.6
    static let center = V3(width / 2, 0, depth / 2)
    static func world(_ c: Int, _ r: Int) -> V2 { V2((Float(c) + 0.5) * pitch, (Float(r) + 0.5) * pitch) }
}

private let stepC = [0, 1, 0, -1], stepR = [-1, 0, 1, 0]

final class Rider {
    let team: Int
    var corners: [V2] = []
    var cornerS: [Float] = []
    var col = 0, row = 0
    var dir = 0
    var s: Float = 0, nodeS: Float = 0
    var speed: Float = 0
    var crashS: Float?
    var hitTeam: Int?
    var alive = true, parked = false, doomed = false
    var runLeft = 0
    var waypoint = V2.zero
    var doomDist = Int.max
    /// Lap rectangle in canonical (unflipped) lattice coordinates.
    var left = 0, top = 0, right = 0, bottom = 0
    var pace: Float = 1, paceLeft: Float = 0
    var lean: Float = 0, wheelAngle: Float = 0, heading: Float = 0, reveal: Float = 0

    init(team: Int) { self.team = team }

    var dirVec: V2 { V2(Float(stepC[dir]), Float(stepR[dir])) }

    func point(_ q: Float) -> V2 {
        var i = corners.count - 1
        while i > 0 && cornerS[i] > q { i -= 1 }
        let d = i + 1 < corners.count ? simd_normalize(corners[i + 1] - corners[i]) : dirVec
        return corners[i] + d * (q - cornerS[i])
    }

    var tailS: Float { s - Arena.bikeLength }
}

struct Crash {
    var pos: V2, heading: V2
    var loser: Int, hitTeam: Int
    var raceTime: Float
}

final class Race {
    enum Phase { case intro, racing, crash, outro, done }
    enum Event { case begin, turn(Int, V2), doom(Int), crash(Crash), dissolve(Int) }

    static let introTime: Float = 2.4, crashTime: Float = 6, outroTime: Float = 3.2
    /// Floor space (nodes) below which a rider gives up and goes for the rival.
    static let cornered = 26
    static let crashWindow: ClosedRange<Float> = 12...50

    var rng: SplitMix
    var phase = Phase.intro
    var phaseTime: Float = 0
    var clock: Float = 0
    var timeScale: Float = 1
    let crashAt: Float
    private(set) var doomedTeam: Int
    var riders: [Rider] = [Rider(team: 0), Rider(team: 1)]
    var events: [Event] = []
    var crash: Crash?
    /// Arc length past which each team's wall has dissolved.
    var front: [Float] = [.infinity, .infinity]
    var speedOverride: Float?

    private var grid: [Int8]
    private var stamp: [Float]
    private var axis: [Int8]
    private var seen: [Int32]
    private var gen: Int32 = 0
    private var contest: [Int32]
    private var contestGen: Int32 = 0
    private var stack: [Int] = []
    private var firstStep: [Int8]

    private let n = Arena.cols * Arena.rows
    private var flipX = false, flipZ = false
    /// Nodes between neighbouring lap lines; each rider's own laps sit twice this apart.
    private var lane = 2
    @inline(__always) private func at(_ c: Int, _ r: Int) -> Int { r * Arena.cols + c }
    @inline(__always) private func inside(_ c: Int, _ r: Int) -> Bool {
        c >= 0 && r >= 0 && c < Arena.cols && r < Arena.rows
    }
    @inline(__always) private func free(_ c: Int, _ r: Int) -> Bool { inside(c, r) && grid[at(c, r)] == 0 }

    init(seed: UInt64) {
        rng = SplitMix(state: seed)
        crashAt = Float.random(in: Race.crashWindow, using: &rng)
        doomedTeam = Bool.random(using: &rng) ? 0 : 1
        grid = .init(repeating: 0, count: n)
        stamp = .init(repeating: 0, count: n)
        axis = .init(repeating: 0, count: n)
        seen = .init(repeating: 0, count: n)
        contest = .init(repeating: 0, count: n)
        firstStep = .init(repeating: -1, count: n)
        stack.reserveCapacity(n)

        // Side by side on the top lane, then wrapped around the screen, nested
        // inward lap after lap. Flips give all four spiral directions.
        lane = Int.random(in: 2...3, using: &rng)
        flipX = Bool.random(using: &rng)
        flipZ = Bool.random(using: &rng)
        let outerTeam = Bool.random(using: &rng) ? 0 : 1
        let startCol = Int.random(in: 10...18, using: &rng)
        lap(riders[outerTeam], inset: 1, startCol: startCol)
        lap(riders[1 - outerTeam], inset: 1 + lane, startCol: startCol + Int.random(in: 0...3, using: &rng))
    }

    private func lap(_ r: Rider, inset: Int, startCol: Int) {
        r.left = inset; r.top = inset
        r.right = Arena.cols - 1 - inset; r.bottom = Arena.rows - 1 - inset
        let (c, w, d) = actual(startCol, inset, 1)
        spawn(r, col: c, row: w, dir: d)
    }

    private func actual(_ c: Int, _ r: Int, _ d: Int) -> (Int, Int, Int) {
        var dir = d
        if flipX && dir % 2 == 1 { dir = (dir + 2) % 4 }
        if flipZ && dir % 2 == 0 { dir = (dir + 2) % 4 }
        return (flipX ? Arena.cols - 1 - c : c, flipZ ? Arena.rows - 1 - r : r, dir)
    }

    /// Clockwise in canonical space: run to the lap's edge, turn, pull that edge in.
    private func spiralDir(_ r: Rider) -> Int? {
        let (c, w, d) = actual(r.col, r.row, r.dir) // the mapping is its own inverse
        let gap = lane * 2
        var next = d
        switch d {
        case 1 where c >= r.right: next = 2; r.top += gap
        case 2 where w >= r.bottom: next = 3; r.right -= gap
        case 3 where c <= r.left: next = 0; r.bottom -= gap
        case 0 where w <= r.top: next = 1; r.left += gap
        default: break
        }
        guard r.left <= r.right, r.top <= r.bottom else { return nil }
        return actual(c, w, next).2
    }

    private func spawn(_ r: Rider, col: Int, row: Int, dir: Int) {
        r.col = col; r.row = row; r.dir = dir
        let p = Arena.world(col, row)
        r.corners = [p - r.dirVec * Arena.pitch]
        r.cornerS = [0]
        r.s = Arena.pitch
        r.nodeS = Arena.pitch
        r.heading = atan2(r.dirVec.y, r.dirVec.x)
        r.runLeft = Int.random(in: 4...9, using: &rng)
        r.waypoint = randomWaypoint()
        grid[at(col, row)] = Int8(r.team + 1)
        stamp[at(col, row)] = r.s
    }

    /// Best of a few random spots, judged by how empty the ground around it is.
    private func randomWaypoint() -> V2 {
        var best = V2.zero, least = Int.max
        for _ in 0..<7 {
            let c = Int.random(in: 2..<(Arena.cols - 2), using: &rng), r = Int.random(in: 2..<(Arena.rows - 2), using: &rng)
            let used = crowding(c, r, radius: 5)
            if used < least { least = used; best = Arena.world(c, r) }
        }
        return best
    }

    var winner: Rider { riders[1 - (crash?.loser ?? doomedTeam)] }

    // MARK: - Clock

    func tick(_ realDt: Float) {
        phaseTime += realDt
        updateTimeScale(realDt)
        let dt = realDt * timeScale
        switch phase {
        case .intro:
            for r in riders { r.reveal = smooth(0, Race.introTime * 0.8, phaseTime) * 5 }
            if phaseTime >= Race.introTime { enter(.racing); events.append(.begin) }
        case .racing:
            clock += dt
            if clock >= crashAt && !riders[doomedTeam].doomed && crash == nil {
                markDoomed(riders[doomedTeam])
            }
            for r in riders where r.alive { ride(r, dt) }
        case .crash:
            ride(winner, dt)
            if let c = crash { dissolve(c.loser, from: 0.7, over: 3.4) }
            if phaseTime >= Race.crashTime {
                enter(.outro)
                events.append(.dissolve(winner.team))
            }
        case .outro:
            ride(winner, dt)
            dissolve(winner.team, from: 0, over: Race.outroTime - 0.8)
            winner.reveal = 5 * (1 - smooth(1.2, Race.outroTime - 0.5, phaseTime))
            if phaseTime >= Race.outroTime { enter(.done) }
        case .done:
            break
        }
    }

    private func enter(_ p: Phase) { phase = p; phaseTime = 0 }

    private func updateTimeScale(_ dt: Float) {
        var target: Float = 1
        switch phase {
        case .racing:
            let r = riders[doomedTeam]
            if r.doomed && r.doomDist <= 1 { target = 0.32 }
        case .crash:
            target = phaseTime < 1.5 ? 0.14 : mixf(0.14, 1, smooth(1.5, 2.8, phaseTime))
        default: break
        }
        timeScale += (target - timeScale) * damp(9, dt)
    }

    private func dissolve(_ team: Int, from start: Float, over length: Float) {
        guard phaseTime >= start else { return }
        let r = riders[team]
        let t = clampf((phaseTime - start) / length, 0, 1)
        front[team] = (1 - t * t) * max(r.tailS, 0) // accelerates as it goes
    }

    // MARK: - Riding

    private func cruise(_ r: Rider) -> Float {
        if phase == .crash || phase == .outro { return 21 }
        let base = (35 + min(clock, 60) * 0.12) * r.pace
        return r.doomed ? base * 1.22 : base
    }

    private func ride(_ r: Rider, _ dt: Float) {
        guard !r.parked else {
            r.speed += (0 - r.speed) * damp(4, dt)
            spin(r, dt)
            return
        }
        // Pace swings trade the lead back and forth.
        r.paceLeft -= dt
        if r.paceLeft <= 0 {
            r.paceLeft = Float.random(in: 2...5, using: &rng)
            r.pace = Float.random(in: 0.9...1.12, using: &rng)
        }
        r.speed += (cruise(r) - r.speed) * damp(2.5, dt)
        r.s += r.speed * dt
        spin(r, dt)
        while r.alive && !r.parked && r.crashS == nil && r.s >= r.nodeS { arrive(r) }
        if let c = r.crashS, r.s >= c {
            r.s = c
            // Only the first hit ends the race; a rider already committed to a
            // wall when the rival goes down stops short of it.
            if phase == .racing { impact(r) } else { r.parked = true; r.crashS = nil }
        }
        pose(r, dt)
    }

    private func spin(_ r: Rider, _ dt: Float) { r.wheelAngle += r.speed * dt / (0.56 * Arena.bikeScale) }

    private func pose(_ r: Rider, _ dt: Float) {
        let chord = r.point(r.s) - r.point(r.tailS)
        let h = atan2(chord.y, chord.x)
        var d = h - r.heading
        while d > .pi { d -= 2 * .pi }
        while d < -.pi { d += 2 * .pi }
        r.heading = h
        let rate = dt > 1e-5 ? d / dt : 0
        r.lean += (clampf(rate * 0.09, -0.6, 0.6) - r.lean) * damp(10, dt)
    }

    private func arrive(_ r: Rider) {
        let (d, into) = decide(r)
        if d != r.dir {
            r.corners.append(Arena.world(r.col, r.row))
            r.cornerS.append(r.nodeS)
            axis[at(r.col, r.row)] = 2
            r.dir = d
            events.append(.turn(r.team, Arena.world(r.col, r.row)))
        }
        let nc = r.col + stepC[d], nr = r.row + stepR[d]
        if into || !free(nc, nr) {
            if phase != .racing { r.parked = true; return }
            r.hitTeam = inside(nc, nr) ? Int(grid[at(nc, nr)]) - 1 : nil
            r.crashS = r.nodeS + Arena.pitch - 0.2
            return
        }
        r.col = nc; r.row = nr
        r.nodeS += Arena.pitch
        grid[at(nc, nr)] = Int8(r.team + 1)
        stamp[at(nc, nr)] = r.nodeS
        axis[at(nc, nr)] = Int8(d % 2)
        r.runLeft -= 1
    }

    private func impact(_ r: Rider) {
        r.alive = false
        let c = Crash(pos: r.point(r.s), heading: r.dirVec, loser: r.team,
                      hitTeam: r.hitTeam ?? -1, raceTime: clock)
        crash = c
        riders[1 - r.team].doomed = false
        events.append(.crash(c))
        enter(.crash)
    }

    // MARK: - Decisions

    private func decide(_ r: Rider) -> (dir: Int, into: Bool) {
        if r.doomed, phase == .racing, let hit = seekTrail(r) { return hit }
        if let d = spiralDir(r), free(r.col + stepC[d], r.row + stepR[d]) { return (d, false) }
        let opp = riders[1 - r.team]
        let opts = [r.dir, (r.dir + 3) % 4, (r.dir + 1) % 4]
        // Ground the rival can reach first is not ground to count on: that is how
        // gaps get slammed shut. Selection scores it out; the panic check does not.
        markContested(opp)
        var areas = [0, 0, 0], rawAreas = [0, 0, 0], touches = [false, false, false]
        for (i, d) in opts.enumerated() where free(r.col + stepC[d], r.row + stepR[d]) {
            rawAreas[i] = flood(r.col + stepC[d], r.row + stepR[d], limit: n)
            areas[i] = max(flood(r.col + stepC[d], r.row + stepR[d], limit: n, avoidContested: true), 1)
            touches[i] = regionTouchesRival(r.col + stepC[d], r.row + stepR[d], opp)
        }
        // A rider must never wall itself off from the rival's trail, or the final
        // crash has nothing to hit.
        let anyTouch = touches.contains(true)
        if anyTouch { for i in 0..<3 where !touches[i] { areas[i] = 0 } }
        let roomiest = areas.max() ?? 0
        // Nearly cornered before the draw came up: this rider's crash comes early,
        // and it goes for the rival's wall while that wall is still in reach.
        if (rawAreas.max() ?? 0) < Race.cornered, phase == .racing, !riders[doomedTeam].doomed, crash == nil {
            if let hit = seekTrail(r) {
                markDoomed(r)
                return hit
            }
            // Sealed off from the rival's trail: the rival takes the fall instead.
            markDoomed(opp)
        }
        // Reaching a waypoint spends it, otherwise riders orbit it into a solid block.
        if simd_distance(Arena.world(r.col, r.row), r.waypoint) < Arena.pitch * 6 { r.waypoint = randomWaypoint() }
        var best = -1
        var bestScore = -Float.infinity
        for (i, d) in opts.enumerated() where areas[i] > 0 {
            // Never trade open floor for style: pockets are off the table.
            if Float(areas[i]) < Float(roomiest) * 0.92 { continue }
            let c = r.col + stepC[d], w = r.row + stepR[d]
            var score: Float = 0
            let run = openRun(c, w, d, limit: 10)
            score += Float(run) * 0.5
            if run == 0 { score -= 3 }
            // Long pulls, then decisive turns.
            if d == r.dir { score += r.runLeft > 0 ? 9 : -5 }
            score -= Float(crowding(c + stepC[d], w + stepR[d], radius: 2)) * 0.55
            let toWay = simd_normalize(r.waypoint - Arena.world(c, w) + V2(0.01, 0.01))
            score += simd_dot(toWay, V2(Float(stepC[d]), Float(stepR[d]))) * 3
            let toOpp = simd_normalize(opp.point(opp.s) - Arena.world(c, w) + V2(0.01, 0.01))
            score += simd_dot(toOpp, V2(Float(stepC[d]), Float(stepR[d]))) * 1.4
            if abs(c - opp.col) + abs(w - opp.row) <= 1 && opp.alive { score -= 18 }
            score += Float.random(in: -1.2...1.2, using: &rng)
            if score > bestScore { bestScore = score; best = d }
        }
        if best >= 0 {
            if best != r.dir {
                r.runLeft = Int.random(in: 2...13, using: &rng)
                if Float.random(in: 0...1, using: &rng) < 0.45 { r.waypoint = randomWaypoint() }
            }
            return (best, false)
        }
        // Boxed in. Prefer the rival's wall so the ending still reads as a hit.
        for d in opts {
            let c = r.col + stepC[d], w = r.row + stepR[d]
            if inside(c, w), grid[at(c, w)] == Int8(opp.team + 1) { return (d, true) }
        }
        return (r.dir, true)
    }

    private func markDoomed(_ r: Rider) {
        doomedTeam = r.team
        r.doomed = true
        events.append(.doom(r.team))
    }

    /// Crowded ground scores low, so riders keep corridors open and spread
    /// across the arena instead of packing walls into one solid block.
    private func crowding(_ c: Int, _ r: Int, radius: Int) -> Int {
        var used = 0
        for y in max(r - radius, 0)...min(r + radius, Arena.rows - 1) {
            for x in max(c - radius, 0)...min(c + radius, Arena.cols - 1) where grid[at(x, y)] != 0 { used += 1 }
        }
        return used
    }

    private func openRun(_ c0: Int, _ r0: Int, _ d: Int, limit: Int) -> Int {
        var c = c0 + stepC[d], r = r0 + stepR[d], n = 0
        while n < limit && free(c, r) { n += 1; c += stepC[d]; r += stepR[d] }
        return n
    }

    private func regionTouchesRival(_ c0: Int, _ r0: Int, _ opp: Rider) -> Bool {
        let drawn = opp.s - Arena.pitch * 2
        let mark = Int8(opp.team + 1)
        gen += 1
        stack.removeAll(keepingCapacity: true)
        stack.append(at(c0, r0))
        seen[at(c0, r0)] = gen
        while let u = stack.popLast() {
            let c = u % Arena.cols, r = u / Arena.cols
            for d in 0..<4 {
                let nc = c + stepC[d], nr = r + stepR[d]
                guard inside(nc, nr) else { continue }
                let v = at(nc, nr)
                if grid[v] == mark && stamp[v] < drawn { return true }
                if grid[v] == 0 && seen[v] != gen { seen[v] = gen; stack.append(v) }
            }
        }
        return false
    }

    /// Nodes the rival can reach within a few moves.
    private func markContested(_ opp: Rider) {
        contestGen += 1
        guard opp.alive else { return }
        var ring = [at(opp.col, opp.row)]
        for _ in 0..<4 {
            var next: [Int] = []
            for u in ring {
                for d in 0..<4 {
                    let nc = u % Arena.cols + stepC[d], nr = u / Arena.cols + stepR[d]
                    guard free(nc, nr), contest[at(nc, nr)] != contestGen else { continue }
                    contest[at(nc, nr)] = contestGen
                    next.append(at(nc, nr))
                }
            }
            ring = next
        }
    }

    private func flood(_ c0: Int, _ r0: Int, limit: Int, avoidContested: Bool = false) -> Int {
        gen += 1
        stack.removeAll(keepingCapacity: true)
        stack.append(at(c0, r0))
        seen[at(c0, r0)] = gen
        var count = 0
        while let u = stack.popLast(), count < limit {
            count += 1
            let c = u % Arena.cols, r = u / Arena.cols
            for d in 0..<4 {
                let nc = c + stepC[d], nr = r + stepR[d]
                guard free(nc, nr) else { continue }
                let v = at(nc, nr)
                if avoidContested && contest[v] == contestGen { continue }
                if seen[v] != gen { seen[v] = gen; stack.append(v) }
            }
        }
        return count
    }

    /// Breadth-first route to the rival's drawn wall. Tries for a clean T-bone
    /// first, then settles for any contact.
    private func seekTrail(_ r: Rider) -> (dir: Int, into: Bool)? {
        for strict in [true, false] {
            if let (d, dist, into) = route(r, strict: strict) {
                r.doomDist = dist
                return (d, into)
            }
        }
        r.doomDist = .max
        return nil
    }

    private func route(_ r: Rider, strict: Bool) -> (Int, Int, Bool)? {
        let opp = riders[1 - r.team]
        let drawn = opp.s - Arena.pitch * 2
        gen += 1
        var queue = [at(r.col, r.row)]
        var depth = [queue[0]: 0]
        seen[queue[0]] = gen
        firstStep[queue[0]] = -1
        var head = 0
        while head < queue.count {
            let u = queue[head]; head += 1
            let c = u % Arena.cols, w = u / Arena.cols
            for d in 0..<4 {
                let nc = c + stepC[d], nr = w + stepR[d]
                guard inside(nc, nr) else { continue }
                let v = at(nc, nr)
                if grid[v] == Int8(opp.team + 1), stamp[v] < drawn, !strict || Int(axis[v]) == (d + 1) % 2 {
                    let first = firstStep[u] < 0 ? d : Int(firstStep[u])
                    return (first, depth[u]!, firstStep[u] < 0)
                }
                if grid[v] == 0 && seen[v] != gen {
                    seen[v] = gen
                    firstStep[v] = firstStep[u] < 0 ? Int8(d) : firstStep[u]
                    depth[v] = depth[u]! + 1
                    queue.append(v)
                }
            }
        }
        return nil
    }
}
