import AppKit

public struct ImageOrientation {
    public var rotationDegrees: CGFloat = 0.0
    public var isFlippedHorizontal: Bool = false
    public var isFlippedVertical: Bool = false

    public init(rotationDegrees: CGFloat = 0.0, isFlippedHorizontal: Bool = false, isFlippedVertical: Bool = false) {
        self.rotationDegrees = rotationDegrees
        self.isFlippedHorizontal = isFlippedHorizontal
        self.isFlippedVertical = isFlippedVertical
    }

    public mutating func rotateRight() {
        // Clockwise rotation in standard graphics context (-90 degrees)
        rotationDegrees = (rotationDegrees - 90.0).truncatingRemainder(dividingBy: 360.0)
        if rotationDegrees < 0 { rotationDegrees += 360.0 }
    }

    public mutating func rotateLeft() {
        // Counter-clockwise rotation in standard graphics context (+90 degrees)
        rotationDegrees = (rotationDegrees + 90.0).truncatingRemainder(dividingBy: 360.0)
        if rotationDegrees < 0 { rotationDegrees += 360.0 }
    }

    public mutating func toggleFlipHorizontal() {
        isFlippedHorizontal.toggle()
    }

    public mutating func toggleFlipVertical() {
        isFlippedVertical.toggle()
    }

    public mutating func reset() {
        rotationDegrees = 0.0
        isFlippedHorizontal = false
        isFlippedVertical = false
    }

    /// Size of an image of `size` after this orientation's rotation.
    public func orientedSize(_ size: NSSize) -> NSSize {
        let norm = ((Int(rotationDegrees) % 360) + 360) % 360
        return (norm == 90 || norm == 270) ? NSSize(width: size.height, height: size.width) : size
    }

    public var isIdentity: Bool {
        let norm = ((Int(rotationDegrees) % 360) + 360) % 360
        return norm == 0 && !isFlippedHorizontal && !isFlippedVertical
    }
}

public extension NSImage {
    func transformed(with orientation: ImageOrientation) -> NSImage {
        if orientation.isIdentity { return self }

        let normDegrees = ((Int(orientation.rotationDegrees) % 360) + 360) % 360
        let radians = orientation.rotationDegrees * .pi / 180.0
        let isRotated90 = (normDegrees == 90 || normDegrees == 270)

        let originalSize = self.size
        guard originalSize.width > 0 && originalSize.height > 0 else { return self }

        let newWidth = isRotated90 ? originalSize.height : originalSize.width
        let newHeight = isRotated90 ? originalSize.width : originalSize.height
        let newSize = NSSize(width: newWidth, height: newHeight)

        let newImage = NSImage(size: newSize)
        newImage.lockFocus()

        guard let context = NSGraphicsContext.current?.cgContext else {
            newImage.unlockFocus()
            return self
        }

        context.translateBy(x: newSize.width / 2.0, y: newSize.height / 2.0)

        if orientation.isFlippedHorizontal {
            context.scaleBy(x: -1.0, y: 1.0)
        }
        if orientation.isFlippedVertical {
            context.scaleBy(x: 1.0, y: -1.0)
        }

        context.rotate(by: radians)

        let rect = NSRect(
            x: -originalSize.width / 2.0,
            y: -originalSize.height / 2.0,
            width: originalSize.width,
            height: originalSize.height
        )
        self.draw(in: rect, from: .zero, operation: .copy, fraction: 1.0)

        newImage.unlockFocus()
        return newImage
    }
}

public extension NSPasteboard {
    func copyImage(_ image: NSImage) {
        clearContents()

        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            writeObjects([image])
            return
        }

        let bitmapRep = NSBitmapImageRep(cgImage: cgImage)
        bitmapRep.size = image.size

        if let pngData = bitmapRep.representation(using: .png, properties: [:]) {
            declareTypes([.png, .tiff], owner: nil)
            setData(pngData, forType: .png)
            if let tiffData = bitmapRep.representation(using: .tiff, properties: [:]) {
                setData(tiffData, forType: .tiff)
            }
        } else {
            writeObjects([image])
        }
    }
}
