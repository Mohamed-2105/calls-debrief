// Dessine l'icône de l'app (micro blanc sur fond dégradé) dans un dossier .iconset, converti ensuite par iconutil.
// Usage : icone <dossier.iconset>

import AppKit

func dessiner(pixels: Int) -> Data? {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                                     samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let c = CGFloat(pixels)
    // Gabarit des icônes macOS : carré arrondi de 824/1024 centré
    let marge = c * 100 / 1024
    let cadre = NSRect(x: marge, y: marge, width: c - 2 * marge, height: c - 2 * marge)
    let forme = NSBezierPath(roundedRect: cadre, xRadius: cadre.width * 0.225, yRadius: cadre.width * 0.225)
    NSGradient(starting: NSColor(srgbRed: 1.0, green: 0.42, blue: 0.36, alpha: 1),
               ending: NSColor(srgbRed: 0.85, green: 0.16, blue: 0.38, alpha: 1))?.draw(in: forme, angle: -90)

    let config = NSImage.SymbolConfiguration(pointSize: cadre.height * 0.5, weight: .semibold)
        .applying(.init(paletteColors: [.white]))
    if let micro = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
        let taille = micro.size
        micro.draw(in: NSRect(x: (c - taille.width) / 2, y: (c - taille.height) / 2, width: taille.width, height: taille.height))
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

let dossier = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: dossier, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for echelle in [1, 2] {
        let nom = echelle == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try dessiner(pixels: base * echelle)?.write(to: dossier.appendingPathComponent(nom))
    }
}
