import AppKit
import Darwin

/// macOS が判定したメモリプレッシャーのレベル。独自の閾値は使わない。
enum PressureLevel: Equatable {
    case normal, warning, critical, unknown

    var label: String {
        switch self {
        case .normal: return "正常"
        case .warning: return "注意"
        case .critical: return "高負荷"
        case .unknown: return "取得できません"
        }
    }

    var color: NSColor {
        switch self {
        case .normal: return .systemGreen
        case .warning: return .systemYellow
        case .critical: return .systemRed
        case .unknown: return .systemGray
        }
    }
}

/// メニューバー表示用の常駐監視。パネルを閉じている間も動くのはこれだけ。
/// - 変化の通知: DispatchSource.makeMemoryPressureSource（カーネルの通知）
/// - 現在値: sysctl `kern.memorystatus_vm_pressure_level`（1=normal, 2=warn, 4=critical）
final class MemoryPressureMonitor {
    var onChange: ((PressureLevel) -> Void)?
    private(set) var level: PressureLevel = .unknown
    private var source: DispatchSourceMemoryPressure?
    private var fallbackTimer: Timer?

    func start() {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
        source.setEventHandler { [weak self, weak source] in
            guard let self else { return }
            var next = Self.readCurrent()
            if next == .unknown, let event = source?.data {
                if event.contains(.critical) { next = .critical }
                else if event.contains(.warning) { next = .warning }
                else if event.contains(.normal) { next = .normal }
            }
            self.update(next)
        }
        source.resume()
        self.source = source
        // 通知の取りこぼしに備えた低頻度の再読込（sysctl 1回のみ）。
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in self?.refresh() }
        timer.tolerance = 10
        RunLoop.main.add(timer, forMode: .common)
        fallbackTimer = timer
        refresh()
    }

    func refresh() { update(Self.readCurrent()) }

    private func update(_ next: PressureLevel) {
        guard next != level else { return }
        level = next
        onChange?(next)
    }

    static func readCurrent() -> PressureLevel {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &value, &size, nil, 0) == 0 else { return .unknown }
        switch value {
        case 1: return .normal
        case 2: return .warning
        case 4: return .critical
        default: return .unknown
        }
    }
}
