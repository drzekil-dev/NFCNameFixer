import AppKit

func color(_ r: CGFloat,_ g: CGFloat,_ b: CGFloat) -> NSColor {
    NSColor(srgbRed: r/255, green: g/255, blue: b/255, alpha: 1)
}

func drawText(_ s: String, font: NSFont, color c: NSColor, centerX: CGFloat, centerY: CGFloat) {
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: c]
    let a = NSAttributedString(string: s, attributes: attrs)
    let sz = a.size()
    a.draw(at: CGPoint(x: centerX - sz.width/2, y: centerY - sz.height/2))
}

func makeIcon(_ size: Int) -> Data {
    let S = CGFloat(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: S, height: S)
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    let cg = ctx.cgContext

    // 배경 스퀘어클(라운드 사각형)
    let inset = S * 0.045
    let rect = CGRect(x: inset, y: inset, width: S - inset*2, height: S - inset*2)
    let radius = rect.width * 0.2237
    let bg = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    cg.saveGState()
    cg.addPath(bg); cg.clip()
    let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [color(91,141,239).cgColor, color(106,76,224).cgColor] as CFArray,
        locations: [0, 1])!
    cg.drawLinearGradient(grad, start: CGPoint(x: 0, y: S), end: CGPoint(x: 0, y: 0), options: [])
    // 상단 광택
    let gloss = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [NSColor.white.withAlphaComponent(0.22).cgColor, NSColor.white.withAlphaComponent(0).cgColor] as CFArray,
        locations: [0, 1])!
    cg.drawLinearGradient(gloss, start: CGPoint(x: 0, y: S), end: CGPoint(x: 0, y: S*0.55), options: [])
    cg.restoreGState()

    // 분해 자모(ㅎ ㅏ ㄴ) — 흐리게, 위쪽
    drawText("ㅎ ㅏ ㄴ", font: .systemFont(ofSize: S*0.105, weight: .semibold),
             color: NSColor.white.withAlphaComponent(0.55), centerX: S/2, centerY: S*0.84)
    // 합쳐지는 화살표
    drawText("↓", font: .systemFont(ofSize: S*0.085, weight: .bold),
             color: NSColor.white.withAlphaComponent(0.6), centerX: S/2, centerY: S*0.725)
    // 히어로 '한'
    drawText("한", font: .systemFont(ofSize: S*0.36, weight: .bold),
             color: .white, centerX: S/2, centerY: S*0.515)

    // 하단 NFC 배지(흰 알약)
    let pillFont = NSFont.systemFont(ofSize: S*0.115, weight: .heavy)
    let pAttr = NSAttributedString(string: "NFC", attributes: [.font: pillFont, .foregroundColor: color(106,76,224)])
    let ps = pAttr.size()
    let padX = S*0.055, padY = S*0.022
    let pillW = ps.width + padX*2, pillH = ps.height + padY*2
    let pillRect = CGRect(x: (S-pillW)/2, y: S*0.105, width: pillW, height: pillH)
    cg.setFillColor(NSColor.white.cgColor)
    cg.addPath(CGPath(roundedRect: pillRect, cornerWidth: pillH/2, cornerHeight: pillH/2, transform: nil))
    cg.fillPath()
    pAttr.draw(at: CGPoint(x: pillRect.midX - ps.width/2, y: pillRect.midY - ps.height/2))

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let outDir = CommandLine.arguments[1]
let sizes = [16,32,64,128,256,512,1024]
for s in sizes {
    let data = makeIcon(s)
    try! data.write(to: URL(fileURLWithPath: "\(outDir)/preview_\(s).png"))
}
print("생성됨: \(outDir)")
