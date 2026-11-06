// STT's icon: the sound of its own name. Usage: icon <iconset folder> <wave.svg>
//
// Measured 2026-11-05 on 42 spoken «STT» (42 voices and takes in 10 languages):
// always three beats, as with «Speech to Text». Three lobes of equal width, each a fast rise and a slower fall, heights
// 1 : 0.81 : 0.73. Silence between lobes is a small bar, three widths tall. White on the dark plate at every size and on
// any background; macOS 27 darkens plain light icons by a hidden heuristic, so the plate is dark on purpose.
//
// Grid at 1024: bar 32, gap 32, heights in steps of 32. So one bar is exactly one device pixel in the smallest
// Retina size (16 pt = 32 px), where the wave moves half a pixel to land on whole pixels.
import AppKit

let lobe: [CGFloat] = [0.65, 1, 0.57]     // the lobe at the centre of each of its three bars, peak = 1
let beats: [CGFloat] = [1, 0.81, 0.73]    // the three lobes
let tallest: CGFloat = 576, bar: CGFloat = 32, pitch: CGFloat = 64, quiet: CGFloat = 96

// Bar heights left to right: lobe, small bar, lobe, small bar, lobe = 11 columns.
var heights: [CGFloat] = []
for (i, b) in beats.enumerated() {
    heights += lobe.map { ($0 * b * tallest / bar).rounded() * bar }
    if i < beats.count - 1 { heights.append(quiet) }
}
let left = 512 - pitch * 5 - bar / 2

func draw(_ size: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let c = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    let u = CGFloat(size) / 1024
    c.scaleBy(x: u, y: u)
    let plate = CGRect(x: 100, y: 100, width: 824, height: 824)
    c.saveGState()
    c.addPath(CGPath(roundedRect: plate, cornerWidth: 824 * 0.225, cornerHeight: 824 * 0.225, transform: nil)); c.clip()
    let rgb = { (v: CGFloat, b: CGFloat) in CGColor(srgbRed: v / 255, green: v / 255, blue: b / 255, alpha: 1) }
    let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [rgb(0x2C, 0x2E), rgb(0x0F, 0x10)] as CFArray, locations: [0, 1])!
    c.drawLinearGradient(g, start: CGPoint(x: 0, y: plate.maxY), end: CGPoint(x: 0, y: plate.minY), options: [])
    c.restoreGState()
    c.setFillColor(.white)
    let shift: CGFloat = size == 32 ? 16 : 0           // the half pixel above
    for (i, h0) in heights.enumerated() {
        // At 64 px and below a bar's two ends land on whole pixels only if its height is an even number of them.
        let h = size <= 64 ? (h0 * u / 2).rounded() * 2 / u : h0
        let r = CGRect(x: left + shift + CGFloat(i) * pitch, y: 512 - h / 2, width: bar, height: h)
        c.addPath(CGPath(roundedRect: r, cornerWidth: bar / 2, cornerHeight: bar / 2, transform: nil))
    }
    c.fillPath()
    return rep
}

let out = CommandLine.arguments[1]
for s in [16, 32, 128, 256, 512] {
    for (m, tail) in [(1, ""), (2, "@2x")] {
        try! draw(s * m).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(out)/icon_\(s)x\(s)\(tail).png"))
    }
}

// The same wave for the site and anywhere else that needs it: one colour, takes the colour of the text around it.
let w = pitch * 10 + bar
var svg = "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 \(Int(w)) \(Int(tallest))\" fill=\"currentColor\">"
for (i, h) in heights.enumerated() {
    svg += "<rect x=\"\(Int(CGFloat(i) * pitch))\" y=\"\(Int((tallest - h) / 2))\" width=\"\(Int(bar))\" height=\"\(Int(h))\" rx=\"\(Int(bar / 2))\"/>"
}
try! (svg + "</svg>\n").write(toFile: CommandLine.arguments[2], atomically: true, encoding: .utf8)
