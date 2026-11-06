import AppKit
import ScreenSaver

/// System entry point. All the work happens in WakelineHostView; this class
/// only deals with the macOS screensaver host, which since Sonoma often leaves
/// its process running after the saver is dismissed.
@objc(WakelineSaverView)
final class WakelineSaverView: ScreenSaverView {
    private var host: WakelineHostView?
    private var hasBeenVisible = false
    private var visibleNow = false

    /// One process can hold a view per display, so stop decisions look at all of them.
    private static let views = NSHashTable<WakelineSaverView>.weakObjects()
    private static var allHiddenSince: CFTimeInterval?
    private static var exitScheduled = false

    /// isPreview is unreliable on Tahoe and the frame can change after init, so
    /// the System Settings thumbnail is identified by its live size.
    private var isThumbnail: Bool {
        if let screen = window?.screen { return bounds.width < screen.frame.width * 0.6 }
        return bounds.width < 640
    }

    override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        animationTimeInterval = 1 / 60
        WakelineSaverView.views.add(self)
        let view = WakelineHostView(frame: bounds, seed: UInt64.random(in: 0...UInt64.max))
        view.autoresizingMask = [.width, .height]
        addSubview(view)
        host = view
        let center = DistributedNotificationCenter.default()
        for name in ["com.apple.screensaver.willstop", "com.apple.screensaver.didstop"] {
            center.addObserver(self, selector: #selector(systemStopped), name: Notification.Name(name), object: nil)
        }
    }

    required init?(coder: NSCoder) { nil }

    deinit { DistributedNotificationCenter.default().removeObserver(self) }

    override var hasConfigureSheet: Bool { false }
    override var configureSheet: NSWindow? { nil }

    override func startAnimation() {
        super.startAnimation()
        host?.resume()
    }

    override func stopAnimation() {
        super.stopAnimation()
        visibleNow = false
        host?.paused = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            visibleNow = false
            host?.paused = true
        } else {
            host?.resume()
        }
    }

    override func animateOneFrame() {
        guard let window else { return }
        visibleNow = window.occlusionState.contains(.visible)
        if visibleNow { hasBeenVisible = true }
        if isThumbnail {
            // A covered System Settings preview stops drawing.
            if hasBeenVisible && !visibleNow { return }
        } else {
            checkAllHidden()
        }
        host?.tick()
    }

    /// Trusts occlusion only once a display has reported visible: the host's
    /// window may never report at all, and a false alarm must not kill a live
    /// saver. One display dropping out must not end the race on the others.
    private func checkAllHidden() {
        let screens = WakelineSaverView.views.allObjects.filter { !$0.isThumbnail }
        guard screens.contains(where: { $0.hasBeenVisible }), !screens.contains(where: { $0.visibleNow }) else {
            WakelineSaverView.allHiddenSince = nil
            return
        }
        let now = CACurrentMediaTime()
        if let since = WakelineSaverView.allHiddenSince {
            if now - since > 2 { systemStopped() }
        } else {
            WakelineSaverView.allHiddenSince = now
        }
    }

    /// This notification reaches every copy of the saver, so a thumbnail in
    /// System Settings keeps running when the full-screen saver ends.
    @objc private func systemStopped() {
        guard !isThumbnail else { return }
        host?.paused = true
        guard !WakelineSaverView.thumbnailOpen, !WakelineSaverView.exitScheduled else { return }
        WakelineSaverView.exitScheduled = true
        // The host relaunches on demand; leaving it alive is what burns CPU overnight.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            WakelineSaverView.exitScheduled = false
            if !WakelineSaverView.thumbnailOpen { exit(0) }
        }
    }

    private static var thumbnailOpen: Bool { views.allObjects.contains { $0.isThumbnail } }
}
