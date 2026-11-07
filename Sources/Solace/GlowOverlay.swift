import AppKit
import QuartzCore

/// A transparent, click-through window that covers one screen.
final class GlowWindow: NSPanel {
    private(set) var glow: GlowView!

    convenience init(screen: NSScreen) {
        self.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                  backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        sharingType = .none // keep the glow out of screenshots & screen sharing
        let view = GlowView(frame: CGRect(origin: .zero, size: screen.frame.size))
        glow = view
        contentView = view
        setFrame(screen.frame, display: false)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Edge glow drawn entirely with Core Animation.
///
/// Battery notes:
/// - Colour blobs drift along the screen edge with keyframe animations that run inside
///   the system compositor — the app itself does no work per frame in Colour mode.
/// - Layers render at 1x (it's a soft glow; Retina pixels are wasted GPU work).
/// - The edge mask is a tiny pre-rendered image scaled up, rebuilt only on resize.
/// - Per-frame updates happen only while music is reacting to audio (capped at 30 fps).
final class GlowView: NSView {
    private let content = CALayer()
    private let base = CALayer()
    private let maskLayer = CALayer()
    private var blobs: [CAGradientLayer] = []

    private var thickness: CGFloat = 60
    private var speed: Double = 1
    private var intensity: Float = 0.8
    private var colors: [NSColor] = [.systemTeal, .systemBlue, .systemPurple]
    private var breathing = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer = CALayer()
        wantsLayer = true
        layer?.contentsScale = 1

        content.frame = bounds
        content.mask = maskLayer
        maskLayer.frame = bounds
        maskLayer.contentsGravity = .resize
        maskLayer.magnificationFilter = .linear
        layer?.addSublayer(content)

        base.frame = bounds
        base.opacity = 0.35
        content.addSublayer(base)

        for _ in 0..<6 {
            let b = CAGradientLayer()
            b.type = .radial
            b.startPoint = CGPoint(x: 0.5, y: 0.5)
            b.endPoint = CGPoint(x: 1, y: 1)
            b.locations = [0, 0.45, 1]
            b.contentsScale = 1
            content.addSublayer(b)
            blobs.append(b)
        }
        rebuild()
        apply(colors: colors, animated: false)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        rebuild()
    }

    // MARK: Configuration

    func configure(thickness: CGFloat, speed: Double, intensity: Float) {
        let geometryChanged = abs(thickness - self.thickness) > 0.5 || abs(speed - self.speed) > 0.001
        self.thickness = thickness
        self.speed = speed
        self.intensity = intensity
        if geometryChanged { rebuild() }
        if !breathing {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            content.opacity = intensity
            CATransaction.commit()
        } else {
            setBreathing(true, period: currentPeriod, force: true)
        }
    }

    func apply(colors newColors: [NSColor], animated: Bool) {
        guard !newColors.isEmpty else { return }
        colors = newColors
        CATransaction.begin()
        if animated { CATransaction.setAnimationDuration(1.4) } else { CATransaction.setDisableActions(true) }
        for (i, b) in blobs.enumerated() {
            let c = newColors[i % newColors.count]
            b.colors = [c.withAlphaComponent(0.95).cgColor,
                        c.withAlphaComponent(0.5).cgColor,
                        c.withAlphaComponent(0).cgColor]
        }
        base.backgroundColor = Self.average(newColors).cgColor
        CATransaction.commit()
    }

    private var currentPeriod: Double = 3

    /// Slow "breathing" (runs in the compositor, zero app CPU).
    func setBreathing(_ on: Bool, period: Double = 3, force: Bool = false) {
        guard on != breathing || force || period != currentPeriod else { return }
        breathing = on
        currentPeriod = period
        content.removeAnimation(forKey: "breathe")
        CATransaction.begin(); CATransaction.setDisableActions(true)
        content.opacity = intensity
        CATransaction.commit()
        guard on else { return }
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = intensity * 0.5
        a.toValue = intensity
        a.duration = period / 2
        a.autoreverses = true
        a.repeatCount = .infinity
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        content.add(a, forKey: "breathe")
    }

    /// A quick double pulse of light around the edges (timer finished).
    func flash(colors flashColors: [NSColor]) {
        apply(colors: flashColors, animated: false)
        let a = CAKeyframeAnimation(keyPath: "opacity")
        a.values = [0, 1, 0.3, 1, 0]
        a.keyTimes = [0, 0.15, 0.4, 0.6, 1]
        a.duration = 2.2
        a.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeIn),
                             CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeIn)]
        content.add(a, forKey: "flash")
        CATransaction.begin(); CATransaction.setDisableActions(true)
        base.opacity = 0.85
        CATransaction.commit()
    }

    /// Audio-reactive frame update. `level` is 0...1.
    func setLevel(_ level: Float) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        content.opacity = intensity * (0.45 + 0.55 * level)
        base.opacity = 0.2 + 0.7 * level
        CATransaction.commit()
    }

    func resetLevel() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        base.opacity = 0.35
        if !breathing { content.opacity = intensity }
        CATransaction.commit()
    }

    // MARK: Geometry

    private func rebuild() {
        let b = bounds
        guard b.width > 0, b.height > 0 else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        content.frame = b
        base.frame = b
        maskLayer.frame = b
        maskLayer.contents = Self.edgeMask(size: b.size, thickness: thickness)

        let path = CGPath(rect: b, transform: nil)
        let perimeter = 2 * (b.width + b.height)
        let d = thickness * 5.5
        for (i, blob) in blobs.enumerated() {
            blob.bounds = CGRect(x: 0, y: 0, width: d, height: d)
            blob.position = CGPoint(x: b.midX, y: b.maxY)
            blob.removeAllAnimations()

            let orbit = CAKeyframeAnimation(keyPath: "position")
            orbit.path = path
            orbit.calculationMode = .paced
            // ~45 pt/s at speed 1 → a slow drift; odd blobs move a bit faster.
            orbit.duration = Double(perimeter) / (45 * max(0.1, speed)) * (i % 2 == 0 ? 1 : 0.78)
            orbit.repeatCount = .infinity
            orbit.timeOffset = orbit.duration * Double(i) / Double(blobs.count)
            orbit.isRemovedOnCompletion = false
            blob.add(orbit, forKey: "orbit")

            let pulse = CABasicAnimation(keyPath: "transform.scale")
            pulse.fromValue = 0.8
            pulse.toValue = 1.2
            pulse.duration = (5 + Double(i) * 1.3) / max(0.1, speed)
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            blob.add(pulse, forKey: "pulse")
        }
        CATransaction.commit()
    }

    /// Soft ring: opaque at the screen edge, fading to clear `thickness` points inward.
    /// Rendered at 1/8 scale — it is a smooth gradient, so upscaling is invisible.
    private static func edgeMask(size: CGSize, thickness: CGFloat) -> CGImage? {
        let scale: CGFloat = 1.0 / 8.0
        let w = max(8, Int(size.width * scale)), h = max(8, Int(size.height * scale))
        let t = max(1, Double(thickness * scale))
        // White, premultiplied by alpha: a layer mask only looks at the alpha channel.
        var px = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            let dy = Double(min(y, h - 1 - y)) + 0.5
            for x in 0..<w {
                let dx = Double(min(x, w - 1 - x)) + 0.5
                // Smooth-min so corners glow as a curve rather than a hard square.
                let k = t * 0.6
                let hmin = max(k - abs(dx - dy), 0) / k
                let dist = min(dx, dy) - hmin * hmin * k * 0.25
                let v = max(0, 1 - dist / t)
                let a = UInt8(min(255, pow(v, 1.8) * 255))
                let o = (y * w + x) * 4
                px[o] = a; px[o + 1] = a; px[o + 2] = a; px[o + 3] = a
            }
        }
        guard let provider = CGDataProvider(data: Data(px) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    private static func average(_ colors: [NSColor]) -> NSColor {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0
        for c in colors {
            let s = c.usingColorSpace(.sRGB) ?? c
            r += s.redComponent; g += s.greenComponent; b += s.blueComponent
        }
        let n = CGFloat(colors.count)
        return NSColor(srgbRed: r / n, green: g / n, blue: b / n, alpha: 1)
    }
}
