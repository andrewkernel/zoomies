import AppKit
import CoreText
import SwiftUI

/// The drifting swirl of faint characters behind everything.
///
/// Rendered off the main thread into a bitmap: per frame, all glyphs of one
/// brightness band go to CoreText in a single call (4 calls per frame instead
/// of thousands of draws). While a tune runs it drops to a low frame rate, so
/// the animation never competes with the benchmark it is decorating.
struct AsciiField: View {
    var speed: Double
    var warmth: Double
    var lowPower: Bool
    @State private var animator = AsciiAnimator()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var scale

    var body: some View {
        GeometryReader { g in
            Group {
                if let img = animator.image {
                    // The bitmap is an alpha mask; the tint is applied here, so warming up costs no re-render.
                    Image(decorative: img, scale: scale).renderingMode(.template).resizable().interpolation(.none)
                        .foregroundStyle(Color(red: 0.62 + 0.30 * warmth, green: 0.64 - 0.17 * warmth, blue: 0.68 - 0.36 * warmth))
                        .animation(.easeInOut(duration: 1.2), value: warmth)
                } else {
                    Color.clear
                }
            }
            .onAppear { animator.configure(size: g.size, scale: scale) }
            .onChange(of: g.size) { _, s in animator.configure(size: s, scale: scale) }
        }
        .onAppear { animator.start() }
        .onDisappear { animator.stop() }
        .onChange(of: speed, initial: true) { _, v in animator.speed = reduceMotion ? 0 : v }
        .onChange(of: lowPower, initial: true) { _, v in animator.fps = v ? 6 : 15 }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

@MainActor @Observable
final class AsciiAnimator {
    var image: CGImage?
    @ObservationIgnored var speed: Double = 0.1 { didSet { state.set(speed: speed) } }
    @ObservationIgnored var fps: Double = 24 { didSet { state.set(fps: fps) } }
    @ObservationIgnored private let state = AsciiState()
    @ObservationIgnored private var task: Task<Void, Never>?

    func configure(size: CGSize, scale: CGFloat) { state.set(size: size, scale: scale) }

    func start() {
        guard task == nil else { return }
        let state = self.state
        let ref = WeakAnimator(self)
        task = Task.detached(priority: .utility) {
            let renderer = AsciiRenderer()
            var last = Date()
            var phase = 0.0
            while !Task.isCancelled {
                let snap = state.snapshot()
                let now = Date()
                phase += now.timeIntervalSince(last) * (0.18 + snap.speed * 0.9)
                last = now
                let visible = await MainActor.run { NSApp.occlusionState.contains(.visible) }
                if visible, let img = renderer.render(size: snap.size, scale: snap.scale, phase: phase) {
                    await MainActor.run { ref.animator?.image = img }
                }
                let interval = visible ? 1 / max(1, snap.fps) : 0.5
                try? await Task.sleep(nanoseconds: UInt64(interval * 1e9))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}

struct WeakAnimator: @unchecked Sendable {
    weak var animator: AsciiAnimator?
    init(_ a: AsciiAnimator) { animator = a }
}

/// Parameters shared between the UI and the render loop.
final class AsciiState: @unchecked Sendable {
    struct Snapshot { var size: CGSize; var scale: CGFloat; var speed: Double; var fps: Double }
    private let lock = NSLock()
    private var s = Snapshot(size: .zero, scale: 2, speed: 0.1, fps: 15)

    func snapshot() -> Snapshot { lock.lock(); defer { lock.unlock() }; return s }
    func set(size: CGSize, scale: CGFloat) { lock.lock(); s.size = size; s.scale = scale; lock.unlock() }
    func set(speed: Double) { lock.lock(); s.speed = speed; lock.unlock() }
    func set(fps: Double) { lock.lock(); s.fps = fps; lock.unlock() }
}

/// Draws one frame. Not thread-safe; owned by the render loop.
final class AsciiRenderer {
    private static let ramp = Array(" .·:;-=+*cxzo#%@")
    private static let bands: [CGFloat] = [0.07, 0.13, 0.21, 0.32]
    private let cellW: CGFloat = 7.4
    private let cellH: CGFloat = 12.5
    private var font: CTFont?
    private var fontScale: CGFloat = 0
    private var glyphs: [CGGlyph] = []

    private func prepare(scale: CGFloat) {
        guard scale != fontScale else { return }
        let f = CTFontCreateWithFontDescriptor(NSFont.monospacedSystemFont(ofSize: 10 * scale, weight: .regular).fontDescriptor as CTFontDescriptor,
                                               10 * scale, nil)
        var chars = Self.ramp.map { UniChar(String($0).utf16.first!) }
        var gl = [CGGlyph](repeating: 0, count: chars.count)
        CTFontGetGlyphsForCharacters(f, &chars, &gl, chars.count)
        font = f
        glyphs = gl
        fontScale = scale
    }

    private var ctx: CGContext?
    private var ctxSize = (0, 0)

    func render(size: CGSize, scale: CGFloat, phase: Double) -> CGImage? {
        guard size.width > 10, size.height > 10 else { return nil }
        prepare(scale: scale)
        guard let font else { return nil }
        let pw = Int(size.width * scale), ph = Int(size.height * scale)
        // One reusable alpha-only bitmap: a quarter of the memory traffic of RGBA.
        if ctx == nil || ctxSize != (pw, ph) {
            ctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: pw,
                            space: CGColorSpace(name: CGColorSpace.linearGray) ?? CGColorSpaceCreateDeviceGray(),
                            bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue)
            ctxSize = (pw, ph)
        }
        guard let ctx else { return nil }
        ctx.clear(CGRect(x: 0, y: 0, width: pw, height: ph))
        let ramp = Self.ramp, bands = Self.bands
        var glyphBuf = Array(repeating: [CGGlyph](), count: bands.count)
        var posBuf = Array(repeating: [CGPoint](), count: bands.count)
        let cols = Int(size.width / cellW) + 1
        let rows = Int(size.height / cellH) + 1
        let cx = size.width * 0.56, cy = size.height * 0.48
        let maxR = Double(max(size.width, size.height)) * 0.62

        for row in 0..<rows {
            let y = CGFloat(row) * cellH + cellH / 2
            for col in 0..<cols {
                let x = CGFloat(col) * cellW + cellW / 2
                let dx = Double(x - cx), dy = Double(y - cy) * 1.18
                let r = (dx * dx + dy * dy).squareRoot()
                guard r < maxR else { continue }
                let theta = atan2(dy, dx)
                let arms = sin(3 * theta + log(r + 18) * 4.2 - phase * 2.2)
                let ring = sin(r * 0.045 - phase * 3.1)
                let falloff = max(0, 1 - r / maxR)
                var v = (0.55 * arms + 0.25 * ring) * 0.5 + 0.5
                v = v * pow(falloff, 0.9) + exp(-r / 70) * 0.5
                guard v > 0.30 else { continue }
                let idx = min(ramp.count - 1, Int((v - 0.30) / 0.70 * Double(ramp.count)))
                guard idx > 0 else { continue }
                let band = min(bands.count - 1, Int(v * falloff * 4.2))
                glyphBuf[band].append(glyphs[idx])
                // CoreGraphics has its origin bottom-left.
                posBuf[band].append(CGPoint(x: (x - cellW / 2) * scale, y: (size.height - y - cellH * 0.3) * scale))
            }
        }
        for b in bands.indices where !glyphBuf[b].isEmpty {
            ctx.setFillColor(CGColor(gray: 1, alpha: bands[b]))
            glyphBuf[b].withUnsafeBufferPointer { g in
                posBuf[b].withUnsafeBufferPointer { p in
                    CTFontDrawGlyphs(font, g.baseAddress!, p.baseAddress!, g.count, ctx)
                }
            }
        }
        return ctx.makeImage()
    }
}
