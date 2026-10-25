import AppKit
import LeanDockCore

/// A click keeps the normal button action; crossing the drag threshold never clicks.
final class DeckKeyButton: NSButton, NSDraggingSource {
    private static let pasteboardType = NSPasteboard.PasteboardType("com.yololippy.LeanDock.key-position")
    struct Payload: Codable {
        var pageID: String
        var keyID: String
    }
    var dragScope = ""
    var payload: (() -> Payload?)?
    var acceptsMove: ((Payload) -> Bool)?
    var onMove: ((Payload) -> Bool)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([Self.pasteboardType])
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([Self.pasteboardType])
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled, let window else { return }
        let origin = convert(event.locationInWindow, from: nil)
        let source = payload?()
        var moved = false
        highlight(true)
        defer { highlight(false) }
        while let next = NSApp.nextEvent(matching: [.leftMouseDragged, .leftMouseUp], until: .distantFuture,
                                          inMode: .eventTracking, dequeue: true) {
            let point = convert(next.locationInWindow, from: nil)
            if next.type == .leftMouseUp {
                if !moved, next.window === window, bounds.contains(point) { performClick(nil) }
                return
            }
            if hypot(point.x - origin.x, point.y - origin.y) < 5 { continue }
            moved = true
            guard let source, let bytes = try? JSONEncoder().encode(source) else { continue }
            let writer = NSPasteboardItem(); writer.setData(bytes, forType: Self.pasteboardType)
            let item = NSDraggingItem(pasteboardWriter: writer)
            item.setDraggingFrame(bounds, contents: image ?? NSImage(size: bounds.size))
            highlight(false)
            let session = beginDraggingSession(with: [item], event: next, source: self)
            session.animatesToStartingPositionsOnCancelOrFail = true
            return
        }
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }
    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }
    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) { alphaValue = 0.45 }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        alphaValue = 1; showDropTarget(false)
    }

    private func acceptedPayload(_ sender: NSDraggingInfo) -> Payload? {
        guard let source = sender.draggingSource as? DeckKeyButton, source !== self,
              !dragScope.isEmpty, source.dragScope == dragScope,
              sender.draggingSourceOperationMask.contains(.move),
              let data = sender.draggingPasteboard.data(forType: Self.pasteboardType), data.count <= 4096,
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              acceptsMove?(payload) == true else { return nil }
        return payload
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let allowed = acceptedPayload(sender) != nil
        showDropTarget(allowed)
        return allowed ? .move : []
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { showDropTarget(false) }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { acceptedPayload(sender) != nil }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { showDropTarget(false) }
        guard let payload = acceptedPayload(sender) else { return false }
        return onMove?(payload) == true
    }
    override func draggingEnded(_ sender: NSDraggingInfo) { showDropTarget(false) }

    private func showDropTarget(_ active: Bool) {
        layer?.borderWidth = active ? 3 : 1
        layer?.borderColor = (active ? NSColor.systemTeal : NSColor.white.withAlphaComponent(0.13)).cgColor
    }
}
