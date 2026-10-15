import AppKit
import SwiftUI

/// A nonmodal, read-only satellite. Removing the owning dock tears the panel
/// down, including when a workspace is closed or a new execution replaces it.
struct CollaborationPreviewWindow: NSViewRepresentable {
    let preview: CollaborationTaskPreview
    let onOpen: () -> Void
    let onClose: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.show(preview: preview, onOpen: onOpen, onClose: onClose)
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.show(preview: preview, onOpen: onOpen, onClose: onClose)
    }
    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) { coordinator.close() }

    @MainActor final class Coordinator: NSObject, NSWindowDelegate {
        private var panel: NSPanel?
        private var current: CollaborationTaskPreview?
        private var onClose: (() -> Void)?
        func show(preview: CollaborationTaskPreview, onOpen: @escaping () -> Void, onClose: @escaping () -> Void) {
            self.onClose = onClose
            if current === preview { return }
            current = preview
            let panel = self.panel ?? NSPanel(contentRect: NSRect(x: 0, y: 0, width: 680, height: 420),
                styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: false)
            panel.title = "AI 任务预览"
            panel.isReleasedWhenClosed = false
            panel.hidesOnDeactivate = true
            panel.animationBehavior = .none
            panel.minSize = NSSize(width: 420, height: 240)
            panel.delegate = self
            panel.contentView = NSHostingView(rootView: CollaborationDraftPreview(preview: preview, open: onOpen, close: { [weak self] in self?.panel?.close() }))
            if self.panel == nil { panel.center() }
            self.panel = panel
            panel.orderFront(nil)
        }
        func windowWillClose(_ notification: Notification) {
            panel?.contentView = nil; panel = nil; current = nil
            onClose?()
        }
        func close() {
            onClose = nil; panel?.delegate = nil; panel?.close(); panel?.contentView = nil
            panel = nil; current = nil
        }
    }
}
