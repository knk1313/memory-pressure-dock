import SwiftUI

enum Format {
    static func bytes(_ value: UInt64?) -> String {
        guard let value else { return "取得できません" }
        return format(Int64(clamping: value), style: .memory)
    }
    static func rate(_ bytesPerSecond: Double) -> String {
        format(Int64(bytesPerSecond.rounded()), style: .decimal) + "/秒"
    }
    static func bitsPerSecond(_ bps: Double) -> String {
        let mbps = bps / 1_000_000
        return mbps >= 100 ? String(format: "%.0f Mbps", mbps) : String(format: "%.1f Mbps", mbps)
    }
    /// 計測した 0 を「Zero KB」ではなく数字で出す（「取得できません」と区別するため）。
    private static func format(_ bytes: Int64, style: ByteCountFormatter.CountStyle) -> String {
        let f = ByteCountFormatter()
        f.countStyle = style
        f.allowsNonnumericFormatting = false
        return f.string(fromByteCount: bytes)
    }
}

struct PanelView: View {
    @ObservedObject var model: PanelModel
    var onQuit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            memorySection
            Divider()
            networkSection
            Divider()
            HStack {
                Spacer()
                Button("終了", action: onQuit).controlSize(.small)
            }
        }
        .padding(16)
        .frame(width: 340)
    }

    // MARK: メモリ

    private var memorySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("メモリ").font(.headline)
            HStack(spacing: 6) {
                Circle().fill(Color(nsColor: model.pressure.color)).frame(width: 10, height: 10)
                    .accessibilityHidden(true)
                Text("メモリプレッシャー: \(model.pressure.label)").fontWeight(.medium)
            }
            .accessibilityElement(children: .combine)
            row("使用メモリ", usedText)
            row("スワップ使用量", Format.bytes(model.memory?.swapUsed))

            Text("メモリ使用量が多いアプリ・プロセス").font(.subheadline).padding(.top, 4)
            if let sample = model.processes {
                if sample.top.isEmpty {
                    Text("取得できません").foregroundStyle(.secondary)
                } else {
                    ForEach(Array(sample.top.enumerated()), id: \.element.id) { index, entry in
                        HStack {
                            Text("\(index + 1).").monospacedDigit().foregroundStyle(.secondary)
                            Text(entry.name).lineLimit(1).truncationMode(.middle)
                            if entry.processCount > 1 {
                                Text("(\(entry.processCount)プロセス)").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(Format.bytes(entry.bytes)).monospacedDigit()
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            } else {
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text("集計中…").foregroundStyle(.secondary) }
            }
        }
    }

    private var usedText: String {
        guard let m = model.memory else { return "集計中…" }
        if m.used == nil && m.total == nil { return "取得できません" }
        return "\(Format.bytes(m.used)) / \(Format.bytes(m.total))"
    }

    // MARK: ネットワーク

    private var networkSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ネットワーク").font(.headline)
            row("接続状態", model.network?.stateLabel ?? "確認中…")
            row("接続種別", connectionKindText)
            row("下り通信量", downText)
            row("上り通信量", upText)
            Text("現在流れているデータ量です。回線の最大速度ではありません。")
                .font(.caption).foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                Button("接続を確認") { model.runConnectivityCheck() }
                    .disabled(isChecking)
                checkResult
            }
            .padding(.top, 4)
        }
    }

    private var isChecking: Bool { if case .measuring = model.check { return true } else { return false } }

    private var connectionKindText: String {
        guard let n = model.network else { return "確認中…" }
        guard n.state == .connected else { return "—" }
        var text = n.kind
        if let ssid = n.wifiName, !ssid.isEmpty { text += "（\(ssid)）" }
        if let iface = n.interfaceName { text += " · \(iface)" }
        return text
    }

    private var downText: String {
        switch model.throughput {
        case .measuring: return "計測中…"
        case .unavailable: return "取得できません"
        case .rate(let r): return Format.rate(r.down)
        }
    }

    private var upText: String {
        switch model.throughput {
        case .measuring: return "計測中…"
        case .unavailable: return "取得できません"
        case .rate(let r): return Format.rate(r.up)
        }
    }

    @ViewBuilder private var checkResult: some View {
        switch model.check {
        case .idle:
            Text("下り・上りの回線速度を約\(SpeedTest.maxRuntime)秒かけて測ります（Apple のサーバーへ数百MBを送受信します）")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .measuring(let startedAt):
            TimelineView(.periodic(from: startedAt, by: 1)) { context in
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("測定中… \(Int(context.date.timeIntervalSince(startedAt)))秒").monospacedDigit()
                }
            }
        case .success(let r):
            VStack(alignment: .leading, spacing: 6) {
                row("下り速度", Format.bitsPerSecond(r.downBitsPerSecond))
                row("上り速度", Format.bitsPerSecond(r.upBitsPerSecond))
                row("応答時間", r.baseRTTMilliseconds.map { "\(Int($0.rounded())) ms" } ?? "取得できません")
                Text("測定先: \(r.endpoint ?? "取得できません")").font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
        case .failure(let reason):
            Text("失敗: \(reason)").foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        case .timeout:
            Text("タイムアウト（\(Int(SpeedTest.timeout))秒以内に終わりませんでした）").foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit().multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }
}
