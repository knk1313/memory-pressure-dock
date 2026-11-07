import Foundation

/// パネルの表示状態。パネルを開いている間だけ定期更新する。
final class PanelModel: ObservableObject {
    enum ThroughputState { case measuring, unavailable, rate(ThroughputSampler.Rate) }
    enum CheckState {
        case idle
        case measuring(startedAt: Date)
        case success(SpeedTest.Result)
        case failure(String)
        case timeout
    }

    @Published var pressure: PressureLevel = .unknown
    @Published var memory: MemorySnapshot?
    @Published var processes: ProcessSample?
    @Published var network: NetworkStatus?
    @Published var throughput: ThroughputState = .measuring
    @Published var check: CheckState = .idle

    private let sampler = ProcessSampler()
    private let throughputSampler = ThroughputSampler()
    private let networkMonitor = NetworkStatusMonitor()
    private let work = DispatchQueue(label: "panel.sampling", qos: .utility)
    private var timers: [Timer] = []
    private var processScanInFlight = false
    private var isOpen = false

    func panelDidOpen() {
        guard !isOpen else { return }
        isOpen = true
        throughput = .measuring
        throughputSampler.reset()
        networkMonitor.start { [weak self] status in self?.network = status }
        refreshMemory()
        refreshProcesses()
        refreshThroughput()
        timers = [
            schedule(every: 2) { [weak self] in self?.refreshMemory() },
            schedule(every: 3) { [weak self] in self?.refreshProcesses() },
            schedule(every: 1) { [weak self] in self?.refreshThroughput() },
        ]
    }

    func panelDidClose() {
        isOpen = false
        timers.forEach { $0.invalidate() }
        timers = []
        networkMonitor.stop()
    }

    func runConnectivityCheck() {
        if case .measuring = check { return }
        check = .measuring(startedAt: Date())
        SpeedTest.run { [weak self] outcome in
            switch outcome {
            case let .success(result): self?.check = .success(result)
            case let .failure(reason): self?.check = .failure(reason)
            case .timeout: self?.check = .timeout
            }
        }
    }

    // MARK: - 更新（重い処理はバックグラウンドで実行し、結果だけをメインスレッドに戻す）

    private func schedule(every interval: TimeInterval, _ block: @escaping () -> Void) -> Timer {
        let t = Timer(timeInterval: interval, repeats: true) { _ in block() }
        t.tolerance = interval * 0.2
        RunLoop.main.add(t, forMode: .common)
        return t
    }

    private func refreshMemory() {
        work.async { [weak self] in
            let snap = MemoryStats.read()
            DispatchQueue.main.async { if self?.isOpen == true { self?.memory = snap } }
        }
    }

    private func refreshProcesses() {
        guard !processScanInFlight else { return }
        processScanInFlight = true
        let sampler = self.sampler
        work.async { [weak self] in
            let sample = sampler.sample(limit: 5)
            DispatchQueue.main.async {
                self?.processScanInFlight = false
                if self?.isOpen == true { self?.processes = sample }
            }
        }
    }

    private func refreshThroughput() {
        // 接続していないときは NWPath の主インターフェースがないので、全インターフェースの合計を測る
        let iface = network?.state == .connected ? network?.interfaceName : nil
        let sampler = throughputSampler
        work.async { [weak self] in
            let result = sampler.sample(interface: iface)
            DispatchQueue.main.async {
                guard self?.isOpen == true else { return }
                switch result {
                case .measuring: self?.throughput = .measuring
                case .unavailable: self?.throughput = .unavailable
                case .rate(let r): self?.throughput = .rate(r)
                }
            }
        }
    }
}
