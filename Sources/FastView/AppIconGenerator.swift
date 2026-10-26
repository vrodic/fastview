import AppKit
import CoreGraphics

public enum AppIconGenerator {
    public static func generateAppIcon(size: CGSize = CGSize(width: 512, height: 512)) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()

        guard let context = NSGraphicsContext.current?.cgContext else {
            image.unlockFocus()
            return image
        }

        let rect = CGRect(origin: .zero, size: size)

        // 1. macOS Squircle Background Clip
        let cornerRadius = size.width * 0.22
        let path = CGPath(roundedRect: rect.insetBy(dx: 16, dy: 16), cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
        context.addPath(path)
        context.clip()

        // Background Gradient (Deep Navy / Midnight Indigo to Electric Dark Cyan)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bgColors = [
            NSColor(calibratedRed: 0.05, green: 0.08, blue: 0.20, alpha: 1.0).cgColor,
            NSColor(calibratedRed: 0.02, green: 0.15, blue: 0.30, alpha: 1.0).cgColor,
            NSColor(calibratedRed: 0.08, green: 0.02, blue: 0.18, alpha: 1.0).cgColor
        ] as CFArray
        let bgLocations: [CGFloat] = [0.0, 0.6, 1.0]
        if let bgGradient = CGGradient(colorsSpace: colorSpace, colors: bgColors, locations: bgLocations) {
            context.drawLinearGradient(bgGradient, start: CGPoint(x: 0, y: size.height), end: CGPoint(x: size.width, y: 0), options: [])
        }

        // 2. Dynamic Speed Motion Lines / Streaks
        context.saveGState()
        context.setBlendMode(.screen)
        let streakColors = [
            NSColor.cyan.withAlphaComponent(0.35).cgColor,
            NSColor.systemTeal.withAlphaComponent(0.20).cgColor,
            NSColor.white.withAlphaComponent(0.15).cgColor
        ]
        for (idx, color) in streakColors.enumerated() {
            context.setStrokeColor(color)
            context.setLineWidth(CGFloat(12 - idx * 3))
            let startY = CGFloat(80 + idx * 60)
            let endY = CGFloat(260 + idx * 80)
            context.move(to: CGPoint(x: 40, y: startY))
            context.addLine(to: CGPoint(x: size.width - 60, y: endY))
            context.strokePath()
        }
        context.restoreGState()

        // 3. Photo / Image Frame (Tilted 8 degrees for speed effect)
        context.saveGState()
        context.translateBy(x: size.width * 0.46, y: size.height * 0.52)
        context.rotate(by: -8.0 * .pi / 180.0)

        let frameW: CGFloat = 260
        let frameH: CGFloat = 200
        let frameRect = CGRect(x: -frameW / 2, y: -frameH / 2, width: frameW, height: frameH)

        // Drop shadow for the photo frame
        context.setShadow(offset: CGSize(width: 0, height: -12), blur: 24, color: NSColor.black.withAlphaComponent(0.55).cgColor)

        // Frame Border (Crisp Glossy White)
        let frameBorderPath = CGPath(roundedRect: frameRect, cornerWidth: 16, cornerHeight: 16, transform: nil)
        context.addPath(frameBorderPath)
        context.setFillColor(NSColor.white.cgColor)
        context.fillPath()

        // Inner Photo Artwork
        let photoInnerRect = frameRect.insetBy(dx: 12, dy: 12)
        let photoPath = CGPath(roundedRect: photoInnerRect, cornerWidth: 10, cornerHeight: 10, transform: nil)
        context.addPath(photoPath)
        context.clip()

        // Landscape Sky Gradient (Orange Sun Sunset)
        let skyColors = [
            NSColor(calibratedRed: 0.98, green: 0.55, blue: 0.20, alpha: 1.0).cgColor,
            NSColor(calibratedRed: 0.95, green: 0.82, blue: 0.35, alpha: 1.0).cgColor,
            NSColor(calibratedRed: 0.30, green: 0.65, blue: 0.90, alpha: 1.0).cgColor
        ] as CFArray
        if let skyGradient = CGGradient(colorsSpace: colorSpace, colors: skyColors, locations: [0.0, 0.45, 1.0]) {
            context.drawLinearGradient(skyGradient, start: CGPoint(x: 0, y: photoInnerRect.minY), end: CGPoint(x: 0, y: photoInnerRect.maxY), options: [])
        }

        // Sun
        context.setFillColor(NSColor.white.withAlphaComponent(0.90).cgColor)
        context.fillEllipse(in: CGRect(x: photoInnerRect.midX + 20, y: photoInnerRect.midY - 10, width: 44, height: 44))

        // Mountains inside photo
        context.setFillColor(NSColor(calibratedRed: 0.15, green: 0.25, blue: 0.45, alpha: 1.0).cgColor)
        let mountain1 = CGMutablePath()
        mountain1.move(to: CGPoint(x: photoInnerRect.minX, y: photoInnerRect.minY))
        mountain1.addLine(to: CGPoint(x: photoInnerRect.minX + 70, y: photoInnerRect.minY + 80))
        mountain1.addLine(to: CGPoint(x: photoInnerRect.minX + 150, y: photoInnerRect.minY))
        mountain1.closeSubpath()
        context.addPath(mountain1)
        context.fillPath()

        context.setFillColor(NSColor(calibratedRed: 0.08, green: 0.15, blue: 0.32, alpha: 1.0).cgColor)
        let mountain2 = CGMutablePath()
        mountain2.move(to: CGPoint(x: photoInnerRect.minX + 80, y: photoInnerRect.minY))
        mountain2.addLine(to: CGPoint(x: photoInnerRect.minX + 170, y: photoInnerRect.minY + 95))
        mountain2.addLine(to: CGPoint(x: photoInnerRect.maxX, y: photoInnerRect.minY))
        mountain2.closeSubpath()
        context.addPath(mountain2)
        context.fillPath()

        context.restoreGState()

        // 4. Fast Motion Arrows / Speed Lightning Bolt (Gold + Neon Cyan Accent)
        context.saveGState()
        context.setShadow(offset: CGSize(width: 2, height: -6), blur: 14, color: NSColor.systemYellow.withAlphaComponent(0.6).cgColor)

        let boltPath = CGMutablePath()
        // Speed Lightning Bolt Overlaid on bottom-right corner
        boltPath.move(to: CGPoint(x: size.width * 0.58, y: size.height * 0.72))
        boltPath.addLine(to: CGPoint(x: size.width * 0.44, y: size.height * 0.46))
        boltPath.addLine(to: CGPoint(x: size.width * 0.54, y: size.height * 0.46))
        boltPath.addLine(to: CGPoint(x: size.width * 0.40, y: size.height * 0.22))
        boltPath.addLine(to: CGPoint(x: size.width * 0.66, y: size.height * 0.48))
        boltPath.addLine(to: CGPoint(x: size.width * 0.54, y: size.height * 0.48))
        boltPath.closeSubpath()

        let boltColors = [
            NSColor(calibratedRed: 1.00, green: 0.90, blue: 0.20, alpha: 1.0).cgColor,
            NSColor(calibratedRed: 1.00, green: 0.50, blue: 0.00, alpha: 1.0).cgColor
        ] as CFArray
        if let boltGradient = CGGradient(colorsSpace: colorSpace, colors: boltColors, locations: [0.0, 1.0]) {
            context.addPath(boltPath)
            context.clip()
            context.drawLinearGradient(boltGradient, start: CGPoint(x: 0, y: size.height), end: CGPoint(x: size.width, y: 0), options: [])
        }

        context.restoreGState()

        // 5. Glossy Rim Glow on Squircle Frame
        context.addPath(path)
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.20).cgColor)
        context.setLineWidth(3.0)
        context.strokePath()

        image.unlockFocus()
        return image
    }

    public func saveAppIconPNG(to path: String) {
        let icon = generateAppIcon()
        if let tiff = icon.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let pngData = rep.representation(using: .png, properties: [:]) {
            try? pngData.write(to: URL(fileURLWithPath: path))
        }
    }
}
