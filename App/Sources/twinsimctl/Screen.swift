import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Coordinate space shared with the model. Screenshots are scaled so the long edge is at most
/// `maxEdge` (vision models downscale larger images, which would break coordinates); every
/// coordinate exchanged with the model (taps, swipes, UI tree bounds) uses that scaled space,
/// and TwinSim converts to guest pixels. maxEdge 0 means guest pixels.
struct ScreenSpace {
    let guest: CGSize
    let maxEdge: Int

    var scale: Double {
        guard maxEdge > 0 else { return 1 }
        return min(1, Double(maxEdge) / Double(max(guest.width, guest.height)))
    }
    var imageSize: CGSize { CGSize(width: (guest.width * scale).rounded(), height: (guest.height * scale).rounded()) }

    func toGuest(_ x: Double, _ y: Double) -> (Int, Int) {
        let gx = Int((x / scale).rounded()), gy = Int((y / scale).rounded())
        return (min(max(0, gx), Int(guest.width) - 1), min(max(0, gy), Int(guest.height) - 1))
    }

    func toImage(_ x: Double, _ y: Double) -> (Int, Int) { (Int((x * scale).rounded()), Int((y * scale).rounded())) }

    var summary: String {
        scale == 1
            ? "Coordinates are guest pixels (\(Int(guest.width))×\(Int(guest.height)))."
            : "Image \(Int(imageSize.width))×\(Int(imageSize.height)) is the guest screen \(Int(guest.width))×\(Int(guest.height)) scaled by \(String(format: "%.4f", scale)). Use image pixel coordinates for tap/swipe; TwinSim converts them."
    }
}

enum Imaging {
    static func size(of data: Data) -> CGSize? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return CGSize(width: w, height: h)
    }

    /// Returns (data, mimeType). Scales to `maxEdge` when needed and re-encodes as JPEG for size.
    static func prepare(_ data: Data, maxEdge: Int, format: String) -> (Data, String) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return (data, "image/png") }
        let size = self.size(of: data) ?? .zero
        let needsScale = maxEdge > 0 && max(size.width, size.height) > CGFloat(maxEdge)
        if !needsScale && format == "png" { return (data, "image/png") }
        let image: CGImage?
        if needsScale {
            image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: maxEdge,
                kCGImageSourceCreateThumbnailWithTransform: true,
            ] as CFDictionary)
        } else {
            image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        }
        guard let image else { return (data, "image/png") }
        let out = NSMutableData()
        let type = format == "png" ? UTType.png : UTType.jpeg
        guard let destination = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil) else { return (data, "image/png") }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return (data, "image/png") }
        return (out as Data, format == "png" ? "image/png" : "image/jpeg")
    }
}

/// Android view hierarchy from `uiautomator dump`.
struct UINode {
    var index: Int
    var className: String
    var text: String
    var resourceId: String
    var contentDesc: String
    var package: String
    var clickable: Bool
    var enabled: Bool
    var focused: Bool
    var scrollable: Bool
    var checked: Bool
    var bounds: CGRect   // guest pixels

    var center: CGPoint { CGPoint(x: bounds.midX, y: bounds.midY) }
    var shortClass: String { className.split(separator: ".").last.map(String.init) ?? className }
    var shortId: String { resourceId.components(separatedBy: ":id/").last ?? resourceId }
    var interesting: Bool { !text.isEmpty || !contentDesc.isEmpty || clickable || scrollable || !resourceId.isEmpty }

    func describe(_ space: ScreenSpace) -> String {
        let c = space.toImage(center.x, center.y)
        let a = space.toImage(bounds.minX, bounds.minY), b = space.toImage(bounds.maxX, bounds.maxY)
        var parts = ["[\(index)] \(shortClass)"]
        if !text.isEmpty { parts.append("text=\"\(text.prefix(80))\"") }
        if !contentDesc.isEmpty { parts.append("desc=\"\(contentDesc.prefix(80))\"") }
        if !resourceId.isEmpty { parts.append("id=\(shortId)") }
        parts.append("center=(\(c.0),\(c.1)) bounds=(\(a.0),\(a.1))-(\(b.0),\(b.1))")
        var flags: [String] = []
        if clickable { flags.append("clickable") }
        if scrollable { flags.append("scrollable") }
        if checked { flags.append("checked") }
        if focused { flags.append("focused") }
        if !enabled { flags.append("disabled") }
        if !flags.isEmpty { parts.append(flags.joined(separator: ",")) }
        return parts.joined(separator: " ")
    }
}

final class UITreeParser: NSObject, XMLParserDelegate {
    private(set) var nodes: [UINode] = []

    static func parse(_ xml: String) -> [UINode] {
        guard let start = xml.range(of: "<?xml") ?? xml.range(of: "<hierarchy") else { return [] }
        let body = String(xml[start.lowerBound...])
        let end = body.range(of: "</hierarchy>").map { String(body[..<$0.upperBound]) } ?? body
        let parser = XMLParser(data: Data(end.utf8))
        let delegate = UITreeParser()
        parser.delegate = delegate
        parser.parse()
        return delegate.nodes
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                attributes a: [String: String] = [:]) {
        guard name == "node" else { return }
        nodes.append(UINode(index: nodes.count, className: a["class"] ?? "", text: a["text"] ?? "",
                            resourceId: a["resource-id"] ?? "", contentDesc: a["content-desc"] ?? "",
                            package: a["package"] ?? "", clickable: a["clickable"] == "true", enabled: a["enabled"] != "false",
                            focused: a["focused"] == "true", scrollable: a["scrollable"] == "true",
                            checked: a["checked"] == "true", bounds: Self.bounds(a["bounds"] ?? "")))
    }

    static func bounds(_ text: String) -> CGRect {
        let numbers = text.split(whereSeparator: { !"-0123456789".contains($0) }).compactMap { Double($0) }
        guard numbers.count == 4 else { return .zero }
        return CGRect(x: numbers[0], y: numbers[1], width: numbers[2] - numbers[0], height: numbers[3] - numbers[1])
    }
}
