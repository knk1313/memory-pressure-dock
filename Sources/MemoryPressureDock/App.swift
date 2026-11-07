import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var panel: PanelController!
    private let pressureMonitor = MemoryPressureMonitor()
    private let model = PanelModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        // ⌘ドラッグで動かした位置を、次の起動に引き継ぐ。
        statusItem.autosaveName = "MemoryPressureDock.status"
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover(_:))
        }

        panel = PanelController(content: PanelView(model: model, onQuit: { NSApp.terminate(nil) }))
        panel.onClose = { [weak self] in self?.model.panelDidClose() }

        pressureMonitor.onChange = { [weak self] level in self?.apply(level) }
        apply(.unknown)
        pressureMonitor.start()
    }

    private func apply(_ level: PressureLevel) {
        model.pressure = level
        guard let button = statusItem.button else { return }
        let description = "メモリプレッシャー: \(level.label)"
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [level.color]))
        let image = NSImage(systemSymbolName: "memorychip.fill", accessibilityDescription: description)?
            .withSymbolConfiguration(config)
        image?.isTemplate = false
        button.image = image
        button.toolTip = description
        button.setAccessibilityLabel(description)
    }

    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        if !panel.isShown {
            pressureMonitor.refresh()
            model.panelDidOpen()
        }
        panel.toggle(from: sender)
        // 直前に閉じたばかりで開かなかった場合は、更新を止めておく
        if !panel.isShown { model.panelDidClose() }
    }
}

@main
enum Main {
    static func main() {
        let args = CommandLine.arguments
        if args.contains("--dump") { Diagnostics.dump(); return }
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            Diagnostics.snapshot(to: args[i + 1], check: !args.contains("--no-check")); return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
