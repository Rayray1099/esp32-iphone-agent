import CoreGraphics

/// One aspect-preserving rectangle for both the screenshot and its targets.
enum TargetCanvasGeometry {
    static func size(image: CGSize?, landscape: Bool, availableWidth: CGFloat, maximumHeight: CGFloat) -> CGSize {
        let ratio: CGFloat
        if let image, image.width > 0, image.height > 0 { ratio = image.width / image.height }
        else { ratio = landscape ? 16 / 9 : 9 / 16 }
        let width = max(1, min(availableWidth, maximumHeight * ratio))
        return CGSize(width: width, height: width / ratio)
    }

    static func normalized(_ point: CGPoint, in size: CGSize) -> (x: Int, y: Int) {
        (min(10000, max(0, Int((point.x / max(1, size.width) * 10000).rounded()))),
         min(10000, max(0, Int((point.y / max(1, size.height) * 10000).rounded()))))
    }
}
