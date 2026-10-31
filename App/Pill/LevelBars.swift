import AppKit

/// Bars that follow the microphone level, mirrored around the middle bar: the center is tallest
/// and each side pair flickers on its own, so the shape pulses from the center without drifting
/// sideways. In crawl mode a single hump travels left to right regardless of sound.
final class LevelBars: NSView {
    var level: CGFloat = 0
    var crawl = false
    var color = NSColor.white
    private var shown: CGFloat = 0
    private var phase: CGFloat = 0
    private let count = 7
    private lazy var jitter = [CGFloat](repeating: 1, count: count / 2 + 1)

    override func draw(_ dirtyRect: NSRect) {
        shown += (level - shown) * 0.35
        phase += 0.18
        for d in jitter.indices {
            jitter[d] += (CGFloat.random(in: 0.35...1) - jitter[d]) * 0.3
        }
        let gap: CGFloat = 3
        let width = (bounds.width - gap * CGFloat(count - 1)) / CGFloat(count)
        color.setFill()
        for i in 0..<count {
            let fraction: CGFloat
            if crawl {
                // Distance from the moving hump, wrapping around the row.
                let span = CGFloat(count + 3)
                let pos = phase.truncatingRemainder(dividingBy: span) - 1.5
                fraction = 0.2 + 0.8 * max(0, 1 - abs(CGFloat(i) - pos) / 2)
            } else {
                let d = abs(i - count / 2) // distance from the middle bar
                fraction = shown * (1 - CGFloat(d) * 0.22) * jitter[d]
            }
            let h = max(width, bounds.height * min(1, fraction))
            let rect = NSRect(x: CGFloat(i) * (width + gap), y: (bounds.height - h) / 2, width: width, height: h)
            NSBezierPath(roundedRect: rect, xRadius: width / 2, yRadius: width / 2).fill()
        }
    }
}
