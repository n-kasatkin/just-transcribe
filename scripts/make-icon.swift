// Writes the brand marks as vector files: the app icon as an Icon Composer bundle
// (App/AppIcon.icon, which Xcode compiles into Assets.car and AppIcon.icns) and the menu-bar
// template glyphs (App/Assets.xcassets/MenuBar*.imageset).
// Usage: swift scripts/make-icon.swift
import Foundation

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

func write(_ text: String, to path: String) throws {
    let url = root.appending(path: path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
}

func n(_ value: Double) -> String { String(format: "%g", (value * 100).rounded() / 100) }

/// A rounded rect as path data, so several can share one evenodd path.
func roundedRect(x: Double, y: Double, width w: Double, height h: Double, radius: Double) -> String {
    let r = min(radius, w / 2, h / 2)
    return "M\(n(x + r)) \(n(y))H\(n(x + w - r))A\(n(r)) \(n(r)) 0 0 1 \(n(x + w)) \(n(y + r))"
        + "V\(n(y + h - r))A\(n(r)) \(n(r)) 0 0 1 \(n(x + w - r)) \(n(y + h))"
        + "H\(n(x + r))A\(n(r)) \(n(r)) 0 0 1 \(n(x)) \(n(y + h - r))"
        + "V\(n(y + r))A\(n(r)) \(n(r)) 0 0 1 \(n(x + r)) \(n(y))Z"
}

/// Vertically centred bars with round caps, spread around `centerX`.
func bars(_ heights: [Double], unit: Double, width: Double, gap: Double, centerX: Double, centerY: Double) -> String {
    let total = Double(heights.count) * width + Double(heights.count - 1) * gap
    return heights.enumerated().map { i, h in
        let height = max(width, unit * h)
        return roundedRect(x: centerX - total / 2 + Double(i) * (width + gap), y: centerY - height / 2,
                           width: width, height: height, radius: width / 2)
    }.joined()
}

func svg(size: (Double, Double), path: String, fill: String) -> String {
    """
    <svg xmlns="http://www.w3.org/2000/svg" width="\(n(size.0))" height="\(n(size.1))" viewBox="0 0 \(n(size.0)) \(n(size.1))">
      <path fill="\(fill)" fill-rule="evenodd" d="\(path)"/>
    </svg>

    """
}

// App icon: the pill's seven bars, white, on Icon Composer's 1024 pt canvas.
let pill: [Double] = [0.28, 0.5, 0.78, 1.0, 0.78, 0.5, 0.28]
try write(svg(size: (1024, 1024),
              path: bars(pill, unit: 480, width: 62, gap: 36, centerX: 512, centerY: 512),
              fill: "#FFFFFF"),
          to: "App/AppIcon.icon/Assets/bars.svg")

// The charcoal fill is a top-to-bottom gradient, #2E2E2E to #0F0F0F; the bars stay flat white.
try write("""
    {
      "fill" : {
        "linear-gradient" : [
          "srgb:0.18039,0.18039,0.18039,1.00000",
          "srgb:0.05882,0.05882,0.05882,1.00000"
        ],
        "orientation" : {
          "start" : { "x" : 0.5, "y" : 0 },
          "stop" : { "x" : 0.5, "y" : 1 }
        }
      },
      "groups" : [
        {
          "layers" : [
            {
              "glass" : false,
              "image-name" : "bars.svg",
              "name" : "bars"
            }
          ],
          "shadow" : { "kind" : "neutral", "opacity" : 0.5 },
          "specular" : false,
          "translucency" : { "enabled" : false, "value" : 0 }
        }
      ],
      "supported-platforms" : { "squares" : [ "macOS" ] }
    }

    """, to: "App/AppIcon.icon/icon.json")

// Menu-bar glyphs share one 20 x 18 pt canvas, so the menu bar does not shift between states.
// Idle shows three bars, recording knocks them out of a filled capsule like the pill,
// transcribing shows three dots like an ellipsis.
let glyphs: [(name: String, size: (Double, Double), path: String)] = [
    ("MenuBarIdle", (20, 18), bars([0.5, 1, 0.5], unit: 14, width: 3.2, gap: 2.4, centerX: 10, centerY: 9)),
    ("MenuBarRecording", (20, 18),
     roundedRect(x: 0, y: 2, width: 20, height: 14, radius: 7)
         + bars([0.45, 1, 0.45], unit: 9, width: 2.6, gap: 2, centerX: 10, centerY: 9)),
    ("MenuBarTranscribing", (20, 18), bars([0, 0, 0], unit: 0, width: 3.2, gap: 2.4, centerX: 10, centerY: 9)),
]
for glyph in glyphs {
    let dir = "App/Assets.xcassets/\(glyph.name).imageset"
    try write(svg(size: glyph.size, path: glyph.path, fill: "#000000"), to: "\(dir)/\(glyph.name).svg")
    try write("""
        {
          "images" : [ { "filename" : "\(glyph.name).svg", "idiom" : "universal" } ],
          "info" : { "author" : "xcode", "version" : 1 },
          "properties" : { "preserves-vector-representation" : true, "template-rendering-intent" : "template" }
        }

        """, to: "\(dir)/Contents.json")
}
try write("""
    {
      "info" : { "author" : "xcode", "version" : 1 }
    }

    """, to: "App/Assets.xcassets/Contents.json")
