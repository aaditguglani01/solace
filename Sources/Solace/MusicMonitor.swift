import AppKit

/// Watches Apple Music without polling: Music broadcasts a notification on every
/// play / pause / track change. Album art is fetched once per track via AppleScript.
@MainActor
final class MusicMonitor: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var title: String?
    @Published private(set) var artist: String?
    @Published private(set) var artwork: NSImage?
    @Published private(set) var palette: [NSColor]?

    /// Called on play/pause and when the track (or its colours) change.
    var onChange: ((_ trackChanged: Bool) -> Void)?

    private var trackKey: String?
    private var observer: NSObjectProtocol?
    private static let bundleID = "com.apple.Music"

    init() {
        observer = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.Music.playerInfo"), object: nil, queue: .main
        ) { [weak self] note in
            let info = note.userInfo ?? [:]
            MainActor.assumeIsolated { self?.handle(info) }
        }
        // Pick up a song that was already playing when Solace launched.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            MainActor.assumeIsolated { self?.syncFromApp() }
        }
    }

    private var musicIsRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).isEmpty
    }

    private func handle(_ info: [AnyHashable: Any]) {
        let state = info["Player State"] as? String
        isPlaying = state == "Playing"
        if state == "Stopped" {
            onChange?(false)
            return
        }
        let name = info["Name"] as? String
        let artistName = info["Artist"] as? String
        let album = info["Album"] as? String
        let pid = (info["PersistentID"] as? NSNumber)?.stringValue
        let key = pid ?? "\(name ?? "")|\(artistName ?? "")|\(album ?? "")"

        title = name
        artist = artistName
        if key != trackKey {
            trackKey = key
            onChange?(true)
            // Give Music a moment to have the artwork ready.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                MainActor.assumeIsolated { self?.loadArtwork() }
            }
        } else {
            onChange?(false)
        }
    }

    func syncFromApp() {
        guard musicIsRunning else { return }
        let script = """
        tell application "Music"
            set s to player state as string
            if s is "stopped" then return s
            return s & linefeed & (name of current track) & linefeed & (artist of current track)
        end tell
        """
        guard let result = Self.run(script)?.stringValue else { return }
        let parts = result.components(separatedBy: "\n")
        isPlaying = parts.first == "playing"
        if parts.count >= 3 {
            title = parts[1]
            artist = parts[2]
            trackKey = "\(parts[1])|\(parts[2])"
            loadArtwork()
        }
        onChange?(true)
    }

    private func loadArtwork() {
        guard musicIsRunning else { return }
        let script = """
        tell application "Music"
            try
                if (count of artworks of current track) > 0 then return raw data of artwork 1 of current track
            end try
            return ""
        end tell
        """
        let data = Self.run(script)?.data
        if let data, data.count > 100, let image = NSImage(data: data) {
            artwork = image
            palette = Palette.extract(from: image)
        } else {
            artwork = nil
            palette = nil
        }
        onChange?(true)
    }

    private static func run(_ source: String) -> NSAppleEventDescriptor? {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        return error == nil ? result : nil
    }
}

/// Picks the album cover's most prominent colour and builds a subtle 3-shade gradient from it.
enum Palette {
    static func extract(from image: NSImage) -> [NSColor] {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return [] }
        let w = 32, h = 32
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let drawn: Bool = px.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return [] }

        struct Bucket { var r = 0.0, g = 0.0, b = 0.0, weight = 0.0, n = 0 }
        let hueBins = 24
        var bins = Array(repeating: Bucket(), count: hueBins)
        var neutral = Bucket()

        for i in stride(from: 0, to: px.count, by: 4) {
            let r = Double(px[i]) / 255, g = Double(px[i + 1]) / 255, b = Double(px[i + 2]) / 255
            let (hue, sat, val) = hsv(r, g, b)
            if sat < 0.2 || val < 0.18 {
                neutral.r += r; neutral.g += g; neutral.b += b; neutral.n += 1
                continue
            }
            let k = min(hueBins - 1, Int(hue * Double(hueBins)))
            let wgt = sat * sat * (0.4 + val)
            bins[k].r += r * wgt; bins[k].g += g * wgt; bins[k].b += b * wgt
            bins[k].weight += wgt; bins[k].n += 1
        }

        // The single most prominent colour: the hue that covers the most of the cover,
        // weighted a little towards vivid pixels so a tiny bright speck can't win
        // but a large muted area still does.
        let colouredPixels = bins.reduce(0) { $0 + $1.n }
        let total = max(1, colouredPixels + neutral.n)
        func score(_ k: Int) -> Double {
            // include neighbouring bins so a hue split across a bin edge isn't penalised
            let l = bins[(k + hueBins - 1) % hueBins], r = bins[(k + 1) % hueBins]
            return Double(bins[k].n) + 0.5 * Double(l.n + r.n) + 8 * bins[k].weight
        }
        let best = bins.indices.filter { bins[$0].n >= 3 }.max { score($0) < score($1) }

        let base: NSColor
        if let k = best, Double(colouredPixels) / Double(total) > 0.06 {
            let bin = bins[k]
            base = vivid(bin.r / bin.weight, bin.g / bin.weight, bin.b / bin.weight)
        } else {
            // Black-and-white cover: a soft white glow, tinted by the average.
            let n = Double(max(1, neutral.n))
            let avg = NSColor(srgbRed: neutral.r / n, green: neutral.g / n, blue: neutral.b / n, alpha: 1)
            base = avg.blended(withFraction: 0.8, of: .white) ?? .white
        }

        // A slight gradient: the same colour with a gentle hue/brightness shift either side.
        return [base,
                shifted(base, by: 0.035, brightness: 1.0),
                shifted(base, by: -0.03, brightness: 0.82)]
    }

    private static func hsv(_ r: Double, _ g: Double, _ b: Double) -> (Double, Double, Double) {
        let mx = max(r, g, b), mn = min(r, g, b), d = mx - mn
        var h = 0.0
        if d > 0 {
            if mx == r { h = ((g - b) / d).truncatingRemainder(dividingBy: 6) }
            else if mx == g { h = (b - r) / d + 2 }
            else { h = (r - g) / d + 4 }
            h /= 6
            if h < 0 { h += 1 }
        }
        return (h, mx == 0 ? 0 : d / mx, mx)
    }

    /// Lift saturation & brightness so colours read as light, not as paint.
    private static func vivid(_ r: Double, _ g: Double, _ b: Double) -> NSColor {
        let (h, s, v) = hsv(r, g, b)
        return NSColor(hue: h, saturation: min(1, max(s, 0.55)), brightness: max(v, 0.9), alpha: 1)
    }

    private static func shifted(_ c: NSColor, by amount: Double, brightness: Double) -> NSColor {
        let rgb = c.usingColorSpace(.sRGB) ?? c
        var h: CGFloat = 0, sat: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 0
        rgb.getHue(&h, saturation: &sat, brightness: &v, alpha: &a)
        var nh = Double(h) + amount
        if nh < 0 { nh += 1 }
        if nh > 1 { nh -= 1 }
        return NSColor(hue: CGFloat(nh), saturation: sat, brightness: min(1, v * CGFloat(brightness)), alpha: 1)
    }
}
