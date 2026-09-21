// Tiny dev harness (TASK-017.03): loads JumpnbumpFireworks.saver the same
// way legacyScreenSaver/System Settings does (NSBundle + NSPrincipalClass)
// and hosts the resulting ScreenSaverView in a plain window, so the
// fireworks animation can be eyeballed without touching System Settings
// (`task screensaver:host`). Not part of FireworksKit's own test target --
// this is a manual visual check, not an XCTest assertion.
import AppKit
import ScreenSaver

final class HostDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var view: ScreenSaverView!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let bundlePath = CommandLine.arguments.count > 1
            ? CommandLine.arguments[1]
            : (ProcessInfo.processInfo.environment["JNB_SAVER_PATH"] ?? "./.build/JumpnbumpFireworks.saver")

        guard let bundle = Bundle(path: bundlePath) else {
            fputs("error: no bundle at \(bundlePath)\n", stderr)
            NSApp.terminate(nil)
            return
        }
        guard bundle.load(), let principalClass = bundle.principalClass as? ScreenSaverView.Type else {
            fputs("error: failed to load principal class from \(bundlePath)\n", stderr)
            NSApp.terminate(nil)
            return
        }

        let frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Jump'n'Bump Fireworks -- dev host"
        window.center()

        guard let saverView = principalClass.init(frame: frame, isPreview: false) else {
            fputs("error: init(frame:isPreview:) returned nil\n", stderr)
            NSApp.terminate(nil)
            return
        }
        view = saverView
        view.autoresizingMask = [.width, .height]
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        view.startAnimation()
        Timer.scheduledTimer(withTimeInterval: view.animationTimeInterval, repeats: true) { [weak self] _ in
            self?.view.animateOneFrame()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        view?.stopAnimation()
        return true
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = HostDelegate()
app.delegate = delegate
app.run()
