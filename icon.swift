// STT's icon: the sound of its own name. Usage: icon <dir> <wave.svg> writes <dir>/light.png, <dir>/dark.png and the svg.
// Since 2026-11-09 an Icon Composer icon (macOS 26+ switches it with the theme, Apple's way): ./build writes icon.json
// and runs actool, the plate is the system's own fill.
//
// Measured 2026-11-05 on 42 spoken «STT» (42 voices and takes in 10 languages):
// always three beats, as with «Speech to Text». Three lobes of equal width, each a fast rise and a slower fall, heights
// 1 : 0.81 : 0.73. Silence between lobes is a small bar, three widths tall.
//
// Grid on the old 824 px plate: bar 32, gap 32, heights in steps of 32 (the svg keeps these units).
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

// light: bars #1C1C1E, dark: white. The plate is the system's fill now; the old 824 px plate becomes the whole
// 1024 canvas, and the system renders every size itself (the per-size pixel snapping of the old .icns is gone).
func draw(_ light: Bool) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let c = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    c.scaleBy(x: 1024 / 824, y: 1024 / 824); c.translateBy(x: -100, y: -100)
    c.setFillColor(light ? CGColor(srgbRed: 0x1C / 255, green: 0x1C / 255, blue: 0x1E / 255, alpha: 1) : .white)
    for (i, h) in heights.enumerated() {
        let r = CGRect(x: left + CGFloat(i) * pitch, y: 512 - h / 2, width: bar, height: h)
        c.addPath(CGPath(roundedRect: r, cornerWidth: bar / 2, cornerHeight: bar / 2, transform: nil))
    }
    c.fillPath()
    return rep
}

let out = CommandLine.arguments[1]
for (n, light) in [("light", true), ("dark", false)] {
    try! draw(light).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(out)/\(n).png"))
}

// The same wave for the site and anywhere else that needs it: one colour, takes the colour of the text around it.
let w = pitch * 10 + bar
var svg = "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 \(Int(w)) \(Int(tallest))\" fill=\"currentColor\">"
for (i, h) in heights.enumerated() {
    svg += "<rect x=\"\(Int(CGFloat(i) * pitch))\" y=\"\(Int((tallest - h) / 2))\" width=\"\(Int(bar))\" height=\"\(Int(h))\" rx=\"\(Int(bar / 2))\"/>"
}
try! (svg + "</svg>\n").write(toFile: CommandLine.arguments[2], atomically: true, encoding: .utf8)
