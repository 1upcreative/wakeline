import Foundation
import Metal

enum WakelineError: Error { case metal(String) }

/// Device, shaders and meshes are shared by every display's renderer.
final class GPU {
    static let shared: GPU? = {
        do { return try GPU() } catch {
            // Without this a failed shader compile is an unexplained black screen.
            NSLog("Wakeline GPU setup failed: %@", String(describing: error))
            return nil
        }
    }()

    let device: MTLDevice
    let queue: MTLCommandQueue
    let library: MTLLibrary
    let runner: Mesh
    let pylon: Mesh

    private init() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw WakelineError.metal("no Metal device")
        }
        self.device = device
        self.queue = queue
        // Bundle(for:) on purpose: inside a saver, Bundle.main is the system host.
        let bundle = Bundle(for: GPU.self)
        guard let src = bundle.url(forResource: "Wakeline", withExtension: "metal"),
              let text = try? String(contentsOf: src, encoding: .utf8),
              let runnerURL = bundle.url(forResource: "runner", withExtension: "mesh"),
              let pylonURL = bundle.url(forResource: "pylon", withExtension: "mesh"),
              let runner = Mesh(url: runnerURL, device: device), let pylon = Mesh(url: pylonURL, device: device)
        else { throw WakelineError.metal("resources missing from bundle") }
        library = try device.makeLibrary(source: text, options: nil)
        self.runner = runner
        self.pylon = pylon
    }

    func function(_ name: String) throws -> MTLFunction {
        guard let f = library.makeFunction(name: name) else { throw WakelineError.metal("missing \(name)") }
        return f
    }
}
