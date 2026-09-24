//
//  ContentView.swift
//  主界面：探测 Trae 容器 → 展示 device id → 一键重置 / 清凭证 / 恢复
//

import SwiftUI

struct ContentView: View {
    @State private var agreed = false
    @State private var containers: [TraeContainer] = []
    @State private var selected: Int? = nil
    @State private var fields: [DeviceField] = []
    @State private var log: [LogEntry] = []
    @State private var busy = false
    @State private var notice = ""

    // 动态版本号：从 Info.plist 读取（构建时由 CI 注入，自动递增）
    private var buildNumber: String {
        (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "0"
    }
    private var appVersion: String {
        let s = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        return "v\(s) · build \(buildNumber)"
    }

    var body: some View {
        if !agreed {
            DisclaimerView(onAccept: { agreed = true; refresh() })
        } else {
            VStack(spacing: 0) {
                header
                ScrollView {
                    VStack(spacing: 12) {
                        containerCard
                        deviceCard
                        actionCard
                        logCard
                    }
                    .padding(16)
                }
            }
        }
    }

    // MARK: - 头部
    private var header: some View {
        HStack {
            Text("T").font(.title2.bold()).foregroundColor(.white)
                .frame(width: 34, height: 34).background(Color.blue).cornerRadius(8)
            VStack(alignment: .leading, spacing: 1) {
                Text("TraeReset iOS").font(.headline)
                Text(appVersion).font(.caption2).foregroundColor(.secondary)
            }
            Spacer()
            Button("关于") { about() }
                .font(.subheadline)
        }
        .padding(12)
        .background(Color.blue.opacity(0.12))
    }

    // MARK: - 容器卡片
    private var containerCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("检测到的 Trae 容器").font(.subheadline.bold())
                Spacer()
                Button("刷新") { refresh() }.font(.caption)
            }
            if containers.isEmpty {
                Text("未找到匹配 Trae 的容器。")
                Text("可能原因：① App 未带 no-sandbox 权限 ② bundle id / 名称不匹配。")
                    .font(.caption).foregroundColor(.secondary)
                    .textSelection(.enabled)
            } else {
                ForEach(containers.indices, id: \.self) { i in
                    Button {
                        selected = i
                        scanFields()
                    } label: {
                        HStack {
                            Circle().fill(selected == i ? Color.blue : Color.gray.opacity(0.4))
                                .frame(width: 8, height: 8)
                            VStack(alignment: .leading) {
                                Text(containers[i].displayName ?? containers[i].bundleId ?? "未知")
                                    .font(.callout)
                                Text(containers[i].bundleId ?? containers[i].id)
                                    .font(.caption2).foregroundColor(.secondary)
                            }
                            Spacer()
                        }
                        .padding(10)
                        .background(selected == i ? Color.blue.opacity(0.08) : Color.gray.opacity(0.06))
                        .cornerRadius(10)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(14)
        .background(.white).cornerRadius(12).shadow(color: .black.opacity(0.05), radius: 4, y: 2)
    }

    // MARK: - 设备字段卡片
    private var deviceCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("设备标识（\(fields.count) 项）").font(.subheadline.bold())
            if fields.isEmpty {
                Text(selected != nil ? "该容器内未检测到 device id 文件。" : "请先选择容器")
                    .font(.caption).foregroundColor(.secondary)
            } else {
                ForEach(fields) { f in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(f.display).font(.caption).foregroundColor(.blue)
                            Text(f.filePath.lastPathComponent)
                                .font(.caption2).foregroundColor(.secondary)
                        }
                        Spacer()
                        Text((f.currentValue ?? "").prefix(16) + "…")
                            .font(.caption2.monospaced()).foregroundColor(.secondary)
                    }
                }
            }
            if !notice.isEmpty {
                Text(notice).font(.caption2).foregroundColor(.orange)
            }
        }
        .padding(14)
        .background(.white).cornerRadius(12).shadow(color: .black.opacity(0.05), radius: 4, y: 2)
    }

    // MARK: - 操作卡片
    private var actionCard: some View {
        VStack(spacing: 10) {
            Text("操作").font(.subheadline.bold()).frame(maxWidth: .infinity, alignment: .leading)
            let disabled = selected == nil || busy
            HStack(spacing: 8) {
                button("一键重置", .blue, disabled: disabled) { doOneClick() }
                button("清除凭证", .orange, disabled: disabled) { doClear() }
            }
            HStack(spacing: 8) {
                button("重置设备ID", .blue, disabled: disabled) { doResetDevice() }
                button("恢复备份", .gray, disabled: disabled) { doRestore() }
            }
            if busy {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .padding(14)
        .background(.white).cornerRadius(12).shadow(color: .black.opacity(0.05), radius: 4, y: 2)
    }

    private func button(_ t: String, _ c: Color, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(t).font(.callout.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 42)
        }
        .tint(c)
        .disabled(disabled)
    }

    // MARK: - 日志卡片
    private var logCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("日志").font(.subheadline.bold())
                Spacer()
                if !log.isEmpty {
                    Button("清空") { log.removeAll() }.font(.caption)
                }
            }
            if log.isEmpty {
                Text("还没有操作记录").font(.caption).foregroundColor(.secondary)
            } else {
                ForEach(log) { e in
                    HStack(alignment: .top, spacing: 6) {
                        Text(timeStr(e.time)).font(.caption2).foregroundColor(.secondary)
                        Text(prefix(e.level) + " " + e.text)
                            .font(.caption).textSelection(.enabled)
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white).cornerRadius(12).shadow(color: .black.opacity(0.05), radius: 4, y: 2)
    }

    // MARK: - 逻辑
    private func refresh() {
        containers = TraeLocator.locate()
        notice = ""
        if let first = containers.first { selected = 0; scanFields() }
        else {
            selected = nil
            addLog(.warn, "未找到 Trae 容器。请确认本 App 以 no-sandbox 安装（TrollStore 安装时带 entitlements）。")
        }
    }

    private func scanFields() {
        guard let i = selected, i < containers.count else { return }
        let c = containers[i]
        guard let dataDir = c.dataDir else {
            fields = []
            notice = "该容器无 data 目录（可能仅有 Bundle）。"
            return
        }
        fields = TraeLocator.scanDeviceFields(in: dataDir)
        if fields.isEmpty {
            notice = "未在该容器内发现 device id 文件。iOS 版 Trae 或许用 Keychain / 服务端绑定——请配合越狱终端脚本探测。"
        } else {
            notice = ""
        }
    }

    private func doOneClick() {
        guard let i = selected else { return }
        runBusy { _ = ResetEngine.oneClickReset(container: containers[i]) }
        refreshResults()
    }
    private func doClear() {
        guard let i = selected, let d = containers[i].dataDir else { return }
        runBusy { let r = ResetEngine.clearCredentials(dataDir: d); appendLines(r.lines) }
    }
    private func doResetDevice() {
        guard let i = selected, let d = containers[i].dataDir else { return }
        runBusy {
            let f = TraeLocator.scanDeviceFields(in: d)
            let r = ResetEngine.resetDeviceFields(f, dataDir: d)
            appendLines(r.lines)
        }
    }
    private func doRestore() {
        guard let i = selected, let d = containers[i].dataDir else { return }
        runBusy { let r = ResetEngine.restoreBackups(dataDir: d); appendLines(r.lines) }
        refreshResults()
    }

    private func refreshResults() { scanFields() }

    private func runBusy(_ body: @escaping () -> Void) {
        busy = true
        DispatchQueue.global(qos: .userInitiated).async {
            body()
            DispatchQueue.main.async {
                busy = false
                addLog(.info, "完成")
            }
        }
    }

    private func appendLines(_ lines: [String]) {
        DispatchQueue.main.async {
            for l in lines { addLog(.info, l) }
        }
    }

    private func addLog(_ lvl: LogEntry.Level, _ text: String) {
        log.insert(LogEntry(time: Date(), level: lvl, text: text), at: 0)
    }
    private func prefix(_ l: LogEntry.Level) -> String {
        switch l {
        case .ok: return "✔"
        case .warn: return "⚠"
        case .error: return "✖"
        case .info: return "·"
        }
    }
    private func timeStr(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f.string(from: d)
    }
    private func about() {
        let msg = """
        TraeReset iOS \(appVersion)
        重置 Trae iOS 版设备标识 / 清除本地登录凭证。

        原理：在 TrollStore 以 no-sandbox 安装后访问 Trae 沙盒，
        重新生成 device id 并清除本地凭证。

        重要：
        - 仅操作本地文件，不修改 Trae App 本体
        - 自动备份（.bak）可恢复
        - iOS 版若用 Keychain/服务端绑定，本工具无效，需越狱终端脚本
        - 仅供个人学习，风险自负
        """
        notice = msg
    }

    // MARK: - 免责声明
}

struct DisclaimerView: View {
    let onAccept: () -> Void
    var body: some View {
        VStack(spacing: 18) {
            Text("T").font(.system(size: 40, weight: .bold)).foregroundColor(.white)
                .frame(width: 64, height: 64).background(Color.blue).cornerRadius(16)
            Text("TraeReset iOS").font(.title2.bold())
            Text("Trae 设备限制重置工具（越狱版）").font(.caption).foregroundColor(.secondary)
            Text("""
            1. 本工具仅供个人学习与技术研究使用，请勿用于商业或非法用途。
            2. 使用本工具产生的一切后果由使用者自行承担。
            3. 本工具不修改 Trae 软件本体，仅操作本地用户数据文件。
            4. 需越狱设备以 TrollStore 安装（带 no-sandbox 权限）。
            """).font(.footnote)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color.gray.opacity(0.08)).cornerRadius(10)
            HStack(spacing: 12) {
                Button("同意并继续") { onAccept() }
                    .font(.callout.bold()).tint(.blue)
                    .frame(maxWidth: .infinity, minHeight: 46)
                Button("退出") { exit(0) }
                    .font(.callout).tint(.gray)
                    .frame(maxWidth: .infinity, minHeight: 46)
            }
        }
        .padding(24)
    }
}
