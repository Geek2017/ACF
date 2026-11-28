import AppKit
import CoreGraphics
import Foundation
import ImageIO

// afc-splash-mac: native macOS AppKit splash screen for Agentic CLI Fleet.
// Renders share/acf/splash.png + splash.json identically to Linux GTK afc-splash, with zero external deps.

struct SplashMeta: Decodable {
    let width: Int
    let height: Int
    let frames: Int
    let durations: [Int]
    let strength: [Double]?
}

struct Options {
    var assetsDir: String = ""
    var text: String = "Starting the fleet…"
    var seconds: Double = 5.0
    var savePath: String? = nil
    var saveFrame: Int? = nil
}

func parseArgs() -> Options {
    var opts = Options()
    let args = Array(CommandLine.arguments.dropFirst())
    var i = 0
    while i < args.count {
        let a = args[i]
        if a == "--assets", i + 1 < args.count {
            opts.assetsDir = args[i + 1]; i += 2
        } else if a == "--text", i + 1 < args.count {
            opts.text = args[i + 1]; i += 2
        } else if a == "--seconds", i + 1 < args.count {
            if let v = Double(args[i + 1]) { opts.seconds = max(1.0, min(v, 30.0)) }
            i += 2
        } else if a == "--save", i + 1 < args.count {
            opts.savePath = args[i + 1]; i += 2
        } else if a == "--frame", i + 1 < args.count {
            opts.saveFrame = Int(args[i + 1]); i += 2
        } else {
            i += 1
        }
    }
    if opts.assetsDir.isEmpty {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for cand in ["\(home)/.local/share/acf", "\(home)/acf/share/acf"] {
            if FileManager.default.fileExists(atPath: "\(cand)/splash.png") {
                opts.assetsDir = cand; break
            }
        }
    }
    return opts
}

func loadCGImage(path: String) -> CGImage? {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(src, 0, nil)
}

final class SplashRenderer {
    static let pad: CGFloat = 16
    static let gap: CGFloat = 18
    static let textW: CGFloat = 190
    static let barH: CGFloat = 3

    let strip: CGImage
    let meta: SplashMeta
    let text: String
    let cardW: CGFloat
    let cardH: CGFloat

    init(strip: CGImage, meta: SplashMeta, text: String) {
        self.strip = strip
        self.meta = meta
        self.text = text
        self.cardW = SplashRenderer.pad + CGFloat(meta.width) + SplashRenderer.gap + SplashRenderer.textW + SplashRenderer.pad
        self.cardH = SplashRenderer.pad + CGFloat(meta.height) + SplashRenderer.pad + SplashRenderer.barH
    }

    func draw(in ctx: CGContext, frameIndex: Int, progress: Double) {
        let w = cardW
        let h = cardH
        let bounds = CGRect(x: 0, y: 0, width: w, height: h)

        // White background + subtle 1px border
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(bounds)
        ctx.setStrokeColor(NSColor(calibratedRed: 0.13, green: 0.19, blue: 0.23, alpha: 0.22).cgColor)
        ctx.setLineWidth(1.0)
        ctx.stroke(CGRect(x: 0.5, y: 0.5, width: w - 1, height: h - 1))

        // Cropped logo frame on the left (CGContext origin is bottom-left)
        let fw = meta.width
        let fh = meta.height
        let cropRect = CGRect(x: frameIndex * fw, y: 0, width: fw, height: fh)
        if let sub = strip.cropping(to: cropRect) {
            let dest = CGRect(x: SplashRenderer.pad, y: SplashRenderer.pad + SplashRenderer.barH, width: CGFloat(fw), height: CGFloat(fh))
            ctx.draw(sub, in: dest)
        }

        // Title + subtitle text on the right
        let x = SplashRenderer.pad + CGFloat(fw) + SplashRenderer.gap
        let midY = SplashRenderer.pad + SplashRenderer.barH + CGFloat(fh) / 2.0
        let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsCtx

        let ink = NSColor(calibratedRed: 0.13, green: 0.19, blue: 0.23, alpha: 1.0)
        let grey = NSColor(calibratedRed: 0.42, green: 0.46, blue: 0.50, alpha: 1.0)
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 16),
            .foregroundColor: ink,
        ]
        let subAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: grey,
        ]
        NSAttributedString(string: "Agentic CLI Fleet", attributes: titleAttrs)
            .draw(at: NSPoint(x: x, y: midY + 2))
        NSAttributedString(string: text, attributes: subAttrs)
            .draw(at: NSPoint(x: x, y: midY - 18))

        NSGraphicsContext.restoreGraphicsState()

        // Progress bar along the bottom edge
        let clamped = max(0.0, min(1.0, progress))
        ctx.setFillColor(NSColor(calibratedRed: 0.16, green: 0.44, blue: 0.87, alpha: 1.0).cgColor)
        ctx.fill(CGRect(x: 1, y: 1, width: (w - 2) * CGFloat(clamped), height: SplashRenderer.barH))
    }

    func savePNG(to path: String, frameIndex: Int, progress: Double) -> Bool {
        let iw = Int(cardW)
        let ih = Int(cardH)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: iw, pixelsHigh: ih,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let gctx = NSGraphicsContext(bitmapImageRep: rep) else {
            return false
        }
        draw(in: gctx.cgContext, frameIndex: frameIndex, progress: progress)
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        do {
            try png.write(to: URL(fileURLWithPath: path))
            return true
        } catch {
            return false
        }
    }
}

final class SplashView: NSView {
    let renderer: SplashRenderer
    var frameIndex: Int = 0
    var progress: Double = 0.0
    var onDismiss: (() -> Void)?

    init(renderer: SplashRenderer) {
        self.renderer = renderer
        super.init(frame: NSRect(x: 0, y: 0, width: renderer.cardW, height: renderer.cardH))
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        renderer.draw(in: ctx, frameIndex: frameIndex, progress: progress)
    }

    override func mouseDown(with event: NSEvent) {
        onDismiss?()
    }
}

let opts = parseArgs()
guard !opts.assetsDir.isEmpty,
      let metaData = try? Data(contentsOf: URL(fileURLWithPath: "\(opts.assetsDir)/splash.json")),
      let meta = try? JSONDecoder().decode(SplashMeta.self, from: metaData),
      meta.frames > 0,
      meta.durations.count >= meta.frames,
      let strip = loadCGImage(path: "\(opts.assetsDir)/splash.png") else {
    exit(0)
}

let rawTotal = max(1, meta.durations.reduce(0, +))
let scale = opts.seconds * 1000.0 / Double(rawTotal)
let timesMs = meta.durations.map { max(16, Int((Double($0) * scale).rounded())) }
let totalMs = max(1, timesMs.reduce(0, +))
let renderer = SplashRenderer(strip: strip, meta: meta, text: opts.text)

if let savePath = opts.savePath {
    let idx = max(0, min(meta.frames - 1, opts.saveFrame ?? (meta.frames - 1)))
    let done = Double(timesMs.prefix(idx + 1).reduce(0, +)) / Double(totalMs)
    exit(renderer.savePNG(to: savePath, frameIndex: idx, progress: done) ? 0 : 1)
}

// Single-instance lock
let lockPath = "/tmp/afc-splash-\(getuid()).lock"
let fd = open(lockPath, O_CREAT | O_WRONLY, 0o600)
if fd >= 0, flock(fd, LOCK_EX | LOCK_NB) != 0 {
    exit(0)
}

final class SplashAppDelegate: NSObject, NSApplicationDelegate {
    let panel: NSPanel
    let onLaunch: () -> Void
    init(panel: NSPanel, onLaunch: @escaping () -> Void) {
        self.panel = panel
        self.onLaunch = onLaunch
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        panel.center()
        panel.orderFrontRegardless()
        onLaunch()
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let panel = NSPanel(
    contentRect: NSRect(x: 0, y: 0, width: renderer.cardW, height: renderer.cardH),
    styleMask: [.borderless, .nonactivatingPanel],
    backing: .buffered,
    defer: false
)
panel.level = .statusBar
panel.isOpaque = false
panel.backgroundColor = .clear
panel.hasShadow = true
panel.hidesOnDeactivate = false
panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
panel.center()

let view = SplashView(renderer: renderer)
view.progress = Double(timesMs[0]) / Double(totalMs)
view.onDismiss = { app.terminate(nil) }
panel.contentView = view

let strength = meta.strength ?? Array(repeating: 1.0, count: meta.frames)
let lastFull = strength.enumerated().filter { $0.element >= 1.0 }.map { $0.offset }.max() ?? (meta.frames - 1)
var cur = 0

func scheduleNext() {
    let delay = Double(timesMs[cur]) / 1000.0
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
        cur += 1
        if cur >= meta.frames {
            app.terminate(nil)
            return
        }
        view.frameIndex = cur
        view.progress = Double(timesMs.prefix(cur + 1).reduce(0, +)) / Double(totalMs)
        if cur > lastFull && cur < strength.count {
            panel.alphaValue = CGFloat(max(0.0, min(1.0, strength[cur])))
        }
        view.needsDisplay = true
        scheduleNext()
    }
}

NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { ev in
    if ev.keyCode == 53 { app.terminate(nil) } // Esc
}
NSEvent.addLocalMonitorForEvents(matching: .keyDown) { ev in
    if ev.keyCode == 53 { app.terminate(nil); return nil }
    return ev
}

// Hard safety cap: never stay up past total + 3s
DispatchQueue.main.asyncAfter(deadline: .now() + Double(totalMs) / 1000.0 + 3.0) {
    app.terminate(nil)
}

let delegate = SplashAppDelegate(panel: panel, onLaunch: { scheduleNext() })
app.delegate = delegate
app.run()
