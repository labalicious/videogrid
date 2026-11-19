import AppKit

/// The view libVLC draws into, plus zoom and pan.
///
/// Zoom works like a camera with the tile's shape: at 1× the camera frames the whole
/// video (with black bars if the shapes differ). Zooming shrinks the camera around the
/// pointer, so the picture grows until it fills the tile. What VLC is told to show is the
/// part of the video inside the camera, done with VLC's crop.
///
/// Gestures: pinch, mouse wheel or ⌘/⌥-scroll zooms around the pointer. Drag a box
/// (or ⇧-drag at any zoom) to zoom to that area. When zoomed, drag or two-finger scroll
/// pans. Double-click resets the zoom.
final class VideoView: NSView {
    weak var player: Player?

    private(set) var zoom: CGFloat = 1
    /// Centre of the camera, in display pixels of the video.
    private var center: CGPoint?
    private var cropDirty = false
    static let maxZoom: CGFloat = 20

    var onMouseDown: (() -> Void)?
    var onDoubleClickUnzoomed: (() -> Void)?
    var onZoomChanged: (() -> Void)?
    /// Rubber-band rectangle while dragging a zoom box (nil when not dragging).
    var onSelectionChanged: ((CGRect?) -> Void)?

    private var dragStart: CGPoint?
    private var boxDragging = false

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Keep VLC's own subview from receiving clicks, so all mouse input lands here.
    override func hitTest(_ point: NSPoint) -> NSView? {
        (!isHidden && frame.contains(point)) ? self : nil
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if zoom > 1 { cropDirty = true }    // tile shape changed, so the crop's shape must too
    }

    // MARK: Geometry

    /// Video size in display pixels (aspect-corrected, rotated) and the factor that
    /// converts display x back to source pixels.
    private var video: (size: CGSize, xScale: CGFloat)? {
        guard let g = player?.geometry else { return nil }
        let src = g.transposed ? CGSize(width: g.size.height, height: g.size.width) : g.size
        let xScale = g.transposed ? 1 / g.sar : g.sar
        return (CGSize(width: src.width * xScale, height: src.height), xScale)
    }

    /// Camera size in display pixels for the current zoom (tile-shaped).
    private func cameraSize(_ v: CGSize) -> CGSize {
        let aspect = bounds.height > 0 ? bounds.width / bounds.height : 1
        let fit = v.width / v.height > aspect
            ? CGSize(width: v.width, height: v.width / aspect)
            : CGSize(width: v.height * aspect, height: v.height)
        return CGSize(width: fit.width / zoom, height: fit.height / zoom)
    }

    private func clamped(_ c: CGPoint, camera: CGSize, video v: CGSize) -> CGPoint {
        func axis(_ value: CGFloat, _ cam: CGFloat, _ len: CGFloat) -> CGFloat {
            cam >= len ? len / 2 : min(max(value, cam / 2), len - cam / 2)
        }
        return CGPoint(x: axis(c.x, camera.width, v.width), y: axis(c.y, camera.height, v.height))
    }

    /// View points per display pixel.
    private func scale(camera: CGSize) -> CGFloat { camera.width > 0 ? bounds.width / camera.width : 1 }

    private func currentCenter(_ v: CGSize) -> CGPoint { center ?? CGPoint(x: v.width / 2, y: v.height / 2) }

    /// Converts a point in the view to display pixels of the video.
    private func videoPoint(_ p: CGPoint, video v: CGSize) -> CGPoint {
        let cam = cameraSize(v)
        let c = currentCenter(v)
        let s = scale(camera: cam)
        return CGPoint(x: c.x + (p.x - bounds.midX) / s, y: c.y + (p.y - bounds.midY) / s)
    }

    // MARK: Zoom & pan

    func setZoom(_ newValue: CGFloat, anchor: CGPoint?) {
        guard let v = video?.size else { return }
        let z = min(max(newValue, 1), Self.maxZoom)
        guard abs(z - zoom) > 0.0001 else { return }
        let a = anchor ?? CGPoint(x: bounds.midX, y: bounds.midY)
        let pinned = videoPoint(a, video: v)           // this video point stays under the pointer
        zoom = z
        let cam = cameraSize(v)
        let s = scale(camera: cam)
        let c = CGPoint(x: pinned.x - (a.x - bounds.midX) / s, y: pinned.y - (a.y - bounds.midY) / s)
        center = clamped(c, camera: cam, video: v)
        changed()
    }

    func zoom(by factor: CGFloat) { setZoom(zoom * factor, anchor: nil) }

    /// Zoom so the given rectangle (view points) fills the tile.
    func zoom(toViewRect r: CGRect) {
        guard let v = video?.size else { return }
        let p0 = videoPoint(CGPoint(x: r.minX, y: r.minY), video: v)
        let p1 = videoPoint(CGPoint(x: r.maxX, y: r.maxY), video: v)
        let box = CGRect(x: min(p0.x, p1.x), y: min(p0.y, p1.y), width: abs(p1.x - p0.x), height: abs(p1.y - p0.y))
            .intersection(CGRect(origin: .zero, size: v))
        guard !box.isNull, box.width > 1, box.height > 1 else { return }
        let aspect = bounds.width / max(bounds.height, 1)
        let camWidth = max(box.width, box.height * aspect)
        zoom = 1
        let fitWidth = cameraSize(v).width
        zoom = min(max(fitWidth / camWidth, 1), Self.maxZoom)
        center = clamped(CGPoint(x: box.midX, y: box.midY), camera: cameraSize(v), video: v)
        changed()
    }

    /// Move the picture with the pointer/fingers (view points).
    func pan(dx: CGFloat, dy: CGFloat) {
        guard zoom > 1, let v = video?.size else { return }
        let cam = cameraSize(v)
        let s = scale(camera: cam)
        let c = currentCenter(v)
        center = clamped(CGPoint(x: c.x - dx / s, y: c.y - dy / s), camera: cam, video: v)
        changed()
    }

    func resetZoom() {
        guard zoom != 1 || center != nil else { return }
        zoom = 1
        center = nil
        changed()
    }

    /// Re-send the crop (e.g. after VLC recreates its video output).
    func reapplyCrop() { cropDirty = true }

    private func changed() {
        cropDirty = true
        onZoomChanged?()
        window?.invalidateCursorRects(for: self)
    }

    /// Called from the window timer, so rapid gestures are coalesced to ≤30 updates/s.
    func applyPendingCrop() {
        guard cropDirty, let player else { return }
        guard zoom > 1.001, let v = video else {
            if player.setCrop(nil) { cropDirty = false }
            return
        }
        let cam = cameraSize(v.size)
        let c = currentCenter(v.size)
        let visible = CGRect(x: c.x - cam.width / 2, y: c.y - cam.height / 2, width: cam.width, height: cam.height)
            .intersection(CGRect(origin: .zero, size: v.size))
        guard !visible.isNull, let g = player.geometry else { return }
        // Display pixels → source pixels.
        let srcW = g.transposed ? g.size.height : g.size.width
        let srcH = g.transposed ? g.size.width : g.size.height
        let w = min(srcW, max(2, (visible.width / v.xScale).rounded()))
        let h = min(srcH, max(2, visible.height.rounded()))
        let x = min(max(0, (visible.minX / v.xScale).rounded()), srcW - w)
        let y = min(max(0, visible.minY.rounded()), srcH - h)
        if player.setCrop(CGRect(x: x, y: y, width: w, height: h)) { cropDirty = false }
    }

    // MARK: Events

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: zoom > 1 ? .openHand : .crosshair)
    }

    override func mouseDown(with event: NSEvent) {
        onMouseDown?()
        if event.clickCount == 2 {
            if zoom > 1 { resetZoom() } else { onDoubleClickUnzoomed?() }
            return
        }
        let p = convert(event.locationInWindow, from: nil)
        dragStart = p
        // Unzoomed (or ⇧ held): drag draws a zoom box. Zoomed: drag pans.
        boxDragging = video != nil && (zoom <= 1.001 || event.modifierFlags.contains(.shift))
        if !boxDragging && zoom > 1 { NSCursor.closedHand.set() }
    }

    override func mouseDragged(with event: NSEvent) {
        if boxDragging, let start = dragStart {
            let p = convert(event.locationInWindow, from: nil)
            let r = CGRect(x: min(start.x, p.x), y: min(start.y, p.y), width: abs(p.x - start.x), height: abs(p.y - start.y))
                .intersection(bounds)
            onSelectionChanged?(r)
        } else {
            pan(dx: event.deltaX, dy: event.deltaY)
        }
    }

    override func mouseUp(with event: NSEvent) {
        if boxDragging, let start = dragStart {
            let p = convert(event.locationInWindow, from: nil)
            let r = CGRect(x: min(start.x, p.x), y: min(start.y, p.y), width: abs(p.x - start.x), height: abs(p.y - start.y))
            if r.width > 8 && r.height > 8 { zoom(toViewRect: r) }
        }
        onSelectionChanged?(nil)
        boxDragging = false
        dragStart = nil
        window?.invalidateCursorRects(for: self)
    }

    override func scrollWheel(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let zoomGesture = !event.hasPreciseScrollingDeltas
            || event.modifierFlags.contains(.command) || event.modifierFlags.contains(.option)
        if zoomGesture {
            let dy = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 40 : event.scrollingDeltaY
            guard dy != 0 else { return }
            setZoom(zoom * pow(1.15, dy), anchor: point)
        } else if zoom > 1 {
            pan(dx: event.scrollingDeltaX, dy: event.scrollingDeltaY)
        } else {
            super.scrollWheel(with: event)
        }
    }

    override func magnify(with event: NSEvent) {
        setZoom(zoom * (1 + event.magnification), anchor: convert(event.locationInWindow, from: nil))
    }
}

/// Dashed rubber-band box shown while dragging out a zoom area.
final class SelectionOverlay: NSView {
    var selection: CGRect? { didSet { needsDisplay = true; isHidden = selection == nil } }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let r = selection, r.width > 0, r.height > 0 else { return }
        // Dim everything outside the box so the zoom target stands out.
        let dim = NSBezierPath(rect: bounds)
        dim.append(NSBezierPath(rect: r).reversed)
        NSColor.black.withAlphaComponent(0.45).setFill()
        dim.fill()
        let box = NSBezierPath(rect: r.insetBy(dx: 0.5, dy: 0.5))
        box.lineWidth = 1.5
        box.setLineDash([6, 4], count: 2, phase: 0)
        NSColor.white.setStroke()
        box.stroke()
    }
}
