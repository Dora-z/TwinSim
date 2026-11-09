import AppKit
import SwiftUI

/// AppKit view hosting the video/screenshot layer. Converts clicks and drags into coordinates
/// normalised to the displayed picture, so the session can map them to guest pixels.
final class ScreenCanvasNSView: NSView {
    var contentLayer: CALayer? {
        didSet {
            oldValue?.removeFromSuperlayer()
            if let contentLayer { layer?.addSublayer(contentLayer); needsLayout = true }
        }
    }
    var contentSize: CGSize? { didSet { needsLayout = true } }
    var onTap: ((CGPoint) -> Void)?
    var onSwipe: ((CGPoint, CGPoint, TimeInterval) -> Void)?
    /// Live touch stream; returns true when handled (then tap/swipe on release is skipped).
    var onTouch: ((ScrcpyControl.TouchAction, CGPoint) -> Bool)?
    var onScroll: ((CGPoint, Double, Double) -> Void)?
    private var liveTracking = false
    private var downPoint: CGPoint?
    private var downTime = Date()
    private let marker = CAShapeLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        marker.fillColor = NSColor.white.withAlphaComponent(0.35).cgColor
        marker.strokeColor = NSColor.white.withAlphaComponent(0.8).cgColor
        marker.lineWidth = 1.5
        marker.opacity = 0
        layer?.addSublayer(marker)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Aspect-fit rectangle of the picture inside the view.
    var pictureRect: CGRect {
        guard let size = contentSize, size.width > 0, size.height > 0 else { return bounds }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let w = size.width * scale, h = size.height * scale
        return CGRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h)
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        contentLayer?.frame = bounds
        marker.frame = bounds
        CATransaction.commit()
    }

    private func normalized(_ event: NSEvent) -> CGPoint? {
        let p = convert(event.locationInWindow, from: nil)
        let rect = pictureRect
        guard rect.contains(p), rect.width > 0, rect.height > 0 else { return nil }
        return CGPoint(x: (p.x - rect.minX) / rect.width, y: (p.y - rect.minY) / rect.height)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        downPoint = normalized(event)
        downTime = Date()
        if let p = downPoint, onTouch?(.down, p) == true { liveTracking = true; flash(at: event) }
    }

    override func mouseDragged(with event: NSEvent) {
        guard liveTracking, let p = clampedNormalized(event) else { return }
        _ = onTouch?(.move, p)
    }

    override func scrollWheel(with event: NSEvent) {
        guard let p = normalized(event) else { return }
        let factor = event.hasPreciseScrollingDeltas ? 0.08 : 1.0
        let dx = Double(event.scrollingDeltaX) * factor, dy = Double(event.scrollingDeltaY) * factor
        if dx != 0 || dy != 0 { onScroll?(p, dx, dy) }
    }

    private func clampedNormalized(_ event: NSEvent) -> CGPoint? {
        let p = convert(event.locationInWindow, from: nil)
        let rect = pictureRect
        guard rect.width > 0, rect.height > 0 else { return nil }
        return CGPoint(x: min(max((p.x - rect.minX) / rect.width, 0), 1), y: min(max((p.y - rect.minY) / rect.height, 0), 1))
    }

    override func mouseUp(with event: NSEvent) {
        if liveTracking {
            liveTracking = false
            downPoint = nil
            if let p = clampedNormalized(event) { _ = onTouch?(.up, p) }
            return
        }
        defer { downPoint = nil }
        guard let start = downPoint, let end = normalized(event) else { return }
        let rect = pictureRect
        let distance = hypot((end.x - start.x) * rect.width, (end.y - start.y) * rect.height)
        if distance < 6 {
            flash(at: event)
            onTap?(start)
        } else {
            onSwipe?(start, end, Date().timeIntervalSince(downTime))
        }
    }

    private func flash(at event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        marker.path = CGPath(ellipseIn: CGRect(x: p.x - 14, y: p.y - 14, width: 28, height: 28), transform: nil)
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 1
        animation.toValue = 0
        animation.duration = 0.45
        marker.add(animation, forKey: "flash")
    }
}

struct ScreenCanvas: NSViewRepresentable {
    let session: ScreenSession
    var interactive: Bool

    func makeNSView(context: Context) -> ScreenCanvasNSView {
        let view = ScreenCanvasNSView()
        view.contentLayer = session.renderer.layer
        return view
    }

    func updateNSView(_ view: ScreenCanvasNSView, context: Context) {
        view.contentSize = session.contentSize
        if interactive {
            view.onTap = { [weak session] p in session?.tap(normalized: p) }
            view.onSwipe = { [weak session] a, b, t in session?.swipe(from: a, to: b, duration: t) }
            view.onTouch = { [weak session] action, p in
                MainActor.assumeIsolated { session?.liveTouch(action, normalized: p) ?? false }
            }
            view.onScroll = { [weak session] p, dx, dy in
                MainActor.assumeIsolated { session?.liveScroll(normalized: p, dx: dx, dy: dy) }
            }
        } else {
            view.onTap = nil
            view.onSwipe = nil
            view.onTouch = nil
            view.onScroll = nil
        }
    }
}
