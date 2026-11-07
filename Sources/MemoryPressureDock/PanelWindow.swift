import AppKit
import SwiftUI

/// メニューバーのアイコンの真下に出すパネル。
/// NSPopover は中身の大きさが後から変わると上に伸びて画面外に切れるため、
/// 位置と大きさを自分で決める。上端をメニューバーの直下に固定し、画面の高さを超えるときはスクロールさせる。
final class PanelController: NSObject, NSWindowDelegate {
    var onClose: (() -> Void)?
    private let panel: KeyablePanel
    private let hostingView: SizeReportingHostingView<AnyView>
    private weak var anchor: NSStatusBarButton?
    private var eventMonitor: Any?
    private var lastClosedAt = Date.distantPast
    private let margin: CGFloat = 6

    var isShown: Bool { panel.isVisible }

    init(content: some View) {
        let root = AnyView(
            content
                .background(VisualEffectBackground())
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        )
        hostingView = SizeReportingHostingView(rootView: root)
        panel = KeyablePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: true)
        super.init()
        if #available(macOS 13.0, *) { hostingView.sizingOptions = [.intrinsicContentSize] }
        hostingView.onSizeChange = { [weak self] in self?.layout() }
        panel.contentView = hostingView
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.delegate = self
        panel.onCancel = { [weak self] in self?.close(reason: "esc") }
    }

    func toggle(from button: NSStatusBarButton) {
        if isShown { close(); return }
        // アイコンのクリックでパネルが閉じた直後の同じクリックで、開き直さない
        if Date().timeIntervalSince(lastClosedAt) < 0.25 { return }
        show(from: button)
    }

    func show(from button: NSStatusBarButton) {
        anchor = button
        layout()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.close(reason: "global mouse")
        }
    }

    func close(reason: String = "toggle") {
        guard isShown else { return }
        if ProcessInfo.processInfo.environment["MPD_DEBUG"] != nil { FileHandle.standardError.write("close: \(reason)\n".data(using: .utf8)!) }
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
        panel.orderOut(nil)
        lastClosedAt = Date()
        onClose?()
    }

    func windowDidResignKey(_ notification: Notification) { close(reason: "resignKey") }

    /// 上端をメニューバーの直下に固定して、中身の大きさに合わせる。
    private func layout() {
        guard let button = anchor, let buttonWindow = button.window else { return }
        let itemFrame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = buttonWindow.screen ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }

        let ideal = hostingView.fittingSize
        let width = ideal.width
        let height = min(ideal.height, visible.height - margin * 2)
        var x = itemFrame.midX - width / 2
        x = max(visible.minX + margin, min(x, visible.maxX - width - margin))
        let top = min(itemFrame.minY, visible.maxY) - margin
        panel.setFrame(NSRect(x: x, y: top - height, width: width, height: height), display: true)
    }
}

final class KeyablePanel: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

/// 中身の大きさが変わったことを知らせる NSHostingView。
final class SizeReportingHostingView<Content: View>: NSHostingView<Content> {
    var onSizeChange: (() -> Void)?
    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        DispatchQueue.main.async { [weak self] in self?.onSizeChange?() }
    }
}

struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .popover
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
