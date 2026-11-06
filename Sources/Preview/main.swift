import AppKit
import Foundation
import simd
#if WAKELINE_TEST
import ScreenSaver
#endif

// Preview window plus test modes:
//   (none)                       live window (F full screen, N next race, Esc quit)
//   --simtest N                  run N races with no window and check the rules
//   --release-test               drop renderers with frames in flight
//   --stills dir seed W H t1,t2  raw stills at the given times
// Built with WAKELINE_TEST=1 only:
//   --record out.mp4 sec seed W H   offline render through ffmpeg
//   --load-saver path.saver         host the built .saver in a window
//   --soak minutes W H              render fast and print memory use
let args = CommandLine.arguments

func simTest(_ n: Int) -> Never {
    var trailHits = 0, ownHits = 0, none = 0, failures = 0
    var durations: [Float] = [], doomLags: [Float] = [], wins = [0, 0], turns: [Int] = []
    for i in 0..<n {
        let race = Race(seed: UInt64(i) &* 2654435761 &+ 99)
        var t: Float = 0
        while race.phase != .done && t < 400 {
            race.tick(1 / 60)
            race.events.removeAll(keepingCapacity: true)
            t += 1 / 60
        }
        guard race.phase == .done, let c = race.crash else {
            failures += 1
            print("FAIL seed#\(i): phase \(race.phase) after \(t)s")
            continue
        }
        if c.hitTeam == 1 - c.loser { trailHits += 1 } else if c.hitTeam == c.loser { ownHits += 1 } else { none += 1 }
        wins[1 - c.loser] += 1
        durations.append(c.raceTime)
        doomLags.append(c.raceTime - race.crashAt)
        turns.append(race.riders.map { $0.corners.count }.reduce(0, +))
    }
    let avg = durations.reduce(0, +) / Float(max(durations.count, 1))
    print("races \(n) failures \(failures)")
    print("hit rival trail \(trailHits)  own trail \(ownHits)  arena edge \(none)")
    print("wins green \(wins[1 - 1]) blue \(wins[1])")
    print("crash time min \(durations.min() ?? 0) avg \(avg) max \(durations.max() ?? 0)")
    print("early (natural) crashes \(doomLags.filter { $0 < 0 }.count); doom drive max \(doomLags.max() ?? 0)s")
    let sorted = durations.sorted()
    if !sorted.isEmpty { print("crash time p5 \(sorted[sorted.count / 20]) median \(sorted[sorted.count / 2]) p95 \(sorted[sorted.count * 19 / 20])") }
    print("turns per race avg \(turns.reduce(0, +) / max(turns.count, 1))")
    exit(failures == 0 ? 0 : 1)
}

func offline(seed: UInt64, w: Int, h: Int) -> (World, Renderer) {
    guard let gpu = GPU.shared else { print("GPU init failed"); dumpGPUError(); exit(2) }
    do { return (World(seed: seed), try Renderer(gpu: gpu)) } catch { print("renderer: \(error)"); exit(2) }
}

func dumpGPUError() {
    if let device = MTLCreateSystemDefaultDevice(), let url = Bundle.main.url(forResource: "Wakeline", withExtension: "metal"),
       let text = try? String(contentsOf: url, encoding: .utf8) {
        do { _ = try device.makeLibrary(source: text, options: nil) } catch { print(error) }
    } else { print("no bundle resource at \(Bundle.main.bundlePath)") }
}

#if WAKELINE_TEST
func record(_ path: String, seconds: Float, seed: UInt64, w: Int, h: Int) -> Never {
    let (world, renderer) = offline(seed: seed, w: w, h: h)
    let ff = Process()
    ff.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
    ff.arguments = ["-y", "-loglevel", "error", "-f", "rawvideo", "-pix_fmt", "bgra", "-s", "\(w)x\(h)", "-r", "60", "-i", "-",
                    "-c:v", "libx264", "-preset", "medium", "-crf", "16", "-pix_fmt", "yuv420p", "-movflags", "+faststart", path]
    let pipe = Pipe()
    ff.standardInput = pipe
    try! ff.run()
    var frame = [UInt8](repeating: 0, count: w * h * 4)
    let total = Int(seconds * 60)
    var gpuSum = 0.0
    var lastCrash: Float = -1
    for i in 0..<total {
        world.tick(1 / 60, aspect: Float(w) / Float(h))
        frame.withUnsafeMutableBytes { renderer.draw(world, drawable: nil, size: (w, h), capture: $0.baseAddress!) }
        gpuSum += renderer.lastGPUTime
        frame.withUnsafeBytes { pipe.fileHandleForWriting.write(Data(bytes: $0.baseAddress!, count: $0.count)) }
        if let c = world.race.crash, c.raceTime != lastCrash {
            lastCrash = c.raceTime
            print(String(format: "crash at video t=%.2f loser %d hit %d", Float(i) / 60, c.loser, c.hitTeam))
        }
        if i % 600 == 0 { print("frame \(i)/\(total) phase \(world.race.phase) races \(world.racesRun)") }
    }
    try! pipe.fileHandleForWriting.close()
    ff.waitUntilExit()
    print("done avg GPU \(gpuSum / Double(total) * 1000) ms")
    exit(ff.terminationStatus)
}

/// Physical memory this process has claimed, GPU memory included.
func footprintMB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
    }
    return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
}

/// Runs simulated minutes as fast as the GPU allows, across many races.
func soak(minutes: Int, w: Int, h: Int) -> Never {
    let (world, renderer) = offline(seed: 2026, w: w, h: h)
    let frames = minutes * 3600
    for i in 0...frames {
        autoreleasepool {
            world.tick(1 / 60, aspect: Float(w) / Float(h))
            renderer.draw(world, drawable: nil, size: (w, h))
        }
        if i % 18000 == 0 {
            print(String(format: "sim %3d min  races %4d  footprint %.1f MB", i / 3600, world.racesRun, footprintMB()))
            fflush(stdout)
        }
    }
    exit(0)
}

#endif

func stills(dir: String, seed: UInt64, w: Int, h: Int, times: [Float]) -> Never {
    let (world, renderer) = offline(seed: seed, w: w, h: h)
    var frame = [UInt8](repeating: 0, count: w * h * 4)
    var t: Float = 0
    for (i, target) in times.sorted().enumerated() {
        while t < target { world.tick(1 / 60, aspect: Float(w) / Float(h)); t += 1 / 60 }
        frame.withUnsafeMutableBytes { renderer.draw(world, drawable: nil, size: (w, h), capture: $0.baseAddress!) }
        let name = String(format: "%@/s%02d.bgra", dir, i)
        FileManager.default.createFile(atPath: name, contents: Data(frame))
        print(name, "phase", world.race.phase)
    }
    exit(0)
}

/// Regression test: dropping a renderer with frames in flight must not abort.
func releaseTest() -> Never {
    guard let gpu = GPU.shared else { print("GPU init failed"); exit(2) }
    for _ in 0..<40 {
        autoreleasepool {
            let world = World(seed: 5)
            world.tick(1 / 60, aspect: 16 / 9)
            guard let r = try? Renderer(gpu: gpu) else { print("renderer failed"); exit(2) }
            r.draw(world, drawable: nil, size: (640, 360))
            r.draw(world, drawable: nil, size: (640, 360))
        }
    }
    Thread.sleep(forTimeInterval: 0.5)
    print("RELEASE TEST PASSED")
    exit(0)
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var host: WakelineHostView?
#if WAKELINE_TEST
    var saver: ScreenSaverView?
#endif
    var timer: Timer?

    func applicationDidFinishLaunching(_ note: Notification) {
        let frame = NSRect(x: 0, y: 0, width: 1600, height: 900)
        window = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Wakeline Preview: F full screen, N next race, Esc quit"
        window.center()
#if WAKELINE_TEST
        if let i = args.firstIndex(of: "--load-saver"), i + 1 < args.count {
            loadSaver(args[i + 1], frame: frame)
            window.makeKeyAndOrderFront(nil)
            return
        }
#endif
        do {
            let view = WakelineHostView(frame: frame, seed: UInt64.random(in: 0...UInt64.max))
            view.autoresizingMask = [.width, .height]
            window.contentView = view
            host = view
            timer = Timer(timeInterval: 1 / 120, repeats: true) { [weak view] _ in view?.tick() }
            RunLoop.main.add(timer!, forMode: .common)
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            switch e.charactersIgnoringModifiers?.lowercased() {
            case "f": self?.window.toggleFullScreen(nil); return nil
            case "n": self?.host?.nextRace(); return nil
            case "\u{1b}", "q": NSApp.terminate(nil); return nil
            default: return e
            }
        }
    }

#if WAKELINE_TEST
    func loadSaver(_ path: String, frame: NSRect) {
        guard let bundle = Bundle(path: path), bundle.load(), let cls = bundle.principalClass as? ScreenSaverView.Type,
              let view = cls.init(frame: frame, isPreview: false) else {
            print("SAVER LOAD FAILED: \(path)")
            exit(3)
        }
        print("SAVER LOADED: \(cls)")
        window.contentView = view
        saver = view
        view.startAnimation()
        timer = Timer(timeInterval: view.animationTimeInterval, repeats: true) { [weak view] _ in view?.animateOneFrame() }
        RunLoop.main.add(timer!, forMode: .common)
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            print("SAVER RAN 4s WITHOUT CRASHING")
            view.stopAnimation()
            if args.contains("--exit-after") { exit(0) }
        }
    }
#endif

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }
}

if args.contains("--release-test") { releaseTest() }
if let i = args.firstIndex(of: "--simtest") { simTest(Int(args[i + 1]) ?? 100) }
#if WAKELINE_TEST
if let i = args.firstIndex(of: "--record") {
    record(args[i + 1], seconds: Float(args[i + 2])!, seed: UInt64(args[i + 3])!, w: Int(args[i + 4])!, h: Int(args[i + 5])!)
}
if let i = args.firstIndex(of: "--soak") {
    soak(minutes: Int(args[i + 1])!, w: Int(args[i + 2])!, h: Int(args[i + 3])!)
}
#endif
if let i = args.firstIndex(of: "--stills") {
    stills(dir: args[i + 1], seed: UInt64(args[i + 2])!, w: Int(args[i + 3])!, h: Int(args[i + 4])!,
           times: args[i + 5].split(separator: ",").compactMap { Float($0) })
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
