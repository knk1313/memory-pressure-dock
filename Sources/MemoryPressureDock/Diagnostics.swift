import Foundation

/// `--dump` で起動したとき、パネルと同じ取得処理の結果を標準出力に出す（動作確認用）。
enum Diagnostics {
    static func dump() {
        print("pressure:", MemoryPressureMonitor.readCurrent().label)
        let m = MemoryStats.read()
        print("memory used/total:", Format.bytes(m.used), "/", Format.bytes(m.total),
              " compressed:", Format.bytes(m.compressed), " swap:", Format.bytes(m.swapUsed), "/", Format.bytes(m.swapTotal))
        let s = ProcessSampler().sample(limit: 5)
        print("processes readable:", s.readableCount, " unreadable:", s.unreadableCount)
        for e in s.top { print("  ", e.name, Format.bytes(e.bytes), "procs=\(e.processCount)") }

        let sem = DispatchSemaphore(value: 0)
        let monitor = NetworkStatusMonitor()
        var status: NetworkStatus?
        monitor.start { status = $0 }
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        monitor.stop()
        if let n = status {
            print("network:", n.stateLabel, n.kind, n.interfaceName ?? "-", "ssid:", n.wifiName ?? "取得できません")
        }
        let t = ThroughputSampler()
        _ = t.sample(interface: status?.interfaceName)
        Thread.sleep(forTimeInterval: 1)
        if case .rate(let r) = t.sample(interface: status?.interfaceName) {
            print("down:", Format.rate(r.down), " up:", Format.rate(r.up), " (\(r.interface))")
        }
        ConnectivityCheck.run { outcome in print("check:", outcome); sem.signal() }
        while sem.wait(timeout: .now()) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    }
}

import AppKit
import SwiftUI

extension Diagnostics {
    /// `--snapshot <path>`: 実データを読み込んだパネルを PNG に書き出す（動作確認用）。
    static func snapshot(to path: String, check: Bool) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let model = PanelModel()
        model.pressure = MemoryPressureMonitor.readCurrent()
        model.panelDidOpen()
        if check { model.runConnectivityCheck() }
        RunLoop.main.run(until: Date().addingTimeInterval(4))
        let host = NSHostingView(rootView: PanelView(model: model, onQuit: {}))
        host.frame.size = host.fittingSize
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        model.panelDidClose()
    }
}
