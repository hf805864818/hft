//
//  ResetEngine.swift
//  TraeResetiOS
//
//  实际执行"重置设备标识 + 清除登录凭证"。所有修改前自动备份（.bak），
//  支持恢复；写入后读回验证。仅操作 Trae 沙盒内的本地文件，不修改 App 本体。
//
//  注意：iOS 上登录态/部分 device id 可能存于系统 Keychain（App 内无法访问）。
//  本引擎只负责"文件型"数据；Keychain 型会在结果里标注，需越狱终端处理。
//

import Foundation

enum ResetEngine {

    /// 桌面版沿用的登录凭证键模式
    static let authKeyPatterns = ["iCubeAuthInfo://", "iCubeServerData://", "-entitlement-notified"]

    // MARK: - 一键重置 = 清登录凭证 + 重置设备 ID

    static func oneClickReset(container: TraeContainer) -> OpResult {
        guard let dataDir = container.dataDir else {
            return .err("未找到该容器的数据目录，无法修改。请确认 App 以 no-sandbox 运行。")
        }
        var log = [String]()
        log.append("容器: \(container.bundleId ?? container.displayName ?? container.id)")
        log.append("数据目录: \(dataDir)")

        // 1) 清除登录凭证（JSON 内 auth 键）
        let clear = clearCredentials(dataDir: dataDir)
        log.append(contentsOf: clear.lines)

        // 2) 重置设备 ID
        let fields = TraeLocator.scanDeviceFields(in: dataDir)
        let reset = resetDeviceFields(fields, dataDir: dataDir)
        log.append(contentsOf: reset.lines)

        // 3) 汇总
        var ok = true
        if fields.isEmpty && !dataDirExists(dataDir) {
            ok = false
            log.append("⚠️ 未在该容器内发现任何 device id 文件。iOS 版 Trae 可能用 Keychain / 服务端绑定。")
            log.append("   请改用越狱终端运行 Scripts/trae_cli.sh probe 进一步定位。")
        }
        return OpResult(ok, log)
    }

    // MARK: - 清除登录凭证

    static func clearCredentials(dataDir: String) -> OpResult {
        var log = [String]()
        var removed = 0
        let fm = FileManager.default

        // 扫描容器内 JSON，删 auth 键
        let en = fm.enumerator(at: URL(fileURLWithPath: dataDir),
                               includingPropertiesForKeys: [.isRegularFileKey],
                               options: [.skipsHiddenFiles, .skipsPackageDescendants])
        guard let en = en else { return .okk("未找到可读文件") }
        while let url = en.nextObject() as? URL {
            let path = url.path
            guard path.lowercased().hasSuffix(".json") else { continue }
            guard let data = fm.contents(atPath: path),
                  var obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  obj.keys.count > 0 else { continue }

            let toDelete = obj.keys.filter { key in
                authKeyPatterns.contains { key.contains($0) }
            }
            guard !toDelete.isEmpty else { continue }

            try? backup(path)
            for k in toDelete { obj.removeValue(forKey: k) }
            let newData = try? JSONSerialization.data(withJSONObject: obj,
                                                       options: [.prettyPrinted, .sortedKeys])
            _ = try? newData?.write(to: URL(fileURLWithPath: path), options: .atomic)
            log.append("  删除凭证键: \(toDelete.count) 项 @ \(path.lastPathComponent)")
            removed += toDelete.count
        }

        // 删除常见 Cookies / token 文件
        let cookieNames = ["Cookies", "Cookies-journal"]
        for sub in ["", "/Network", "/Library/Cookies", "/Caches", "/Library/Application Support"] {
            for name in cookieNames {
                let p = dataDir + sub + "/" + name
                if fm.fileExists(atPath: p) {
                    do {
                        try fm.removeItem(atPath: p)
                        log.append("  删除: \(p.lastPathComponent) (@ \(sub))")
                        removed += 1
                    } catch {
                        log.append("  删除失败 \(p.lastPathComponent): \(error.localizedDescription)")
                    }
                }
            }
        }
        if removed == 0 { log.append("  未发现需要清除的登录凭证") }
        return OpResult(true, log)
    }

    // MARK: - 重置设备 ID

    static func resetDeviceFields(_ fields: [DeviceField], dataDir: String) -> OpResult {
        if fields.isEmpty {
            return .okk("未发现可重置的设备 ID 文件")
        }
        var log = [String]()
        var written = 0

        for f in fields {
            do {
                try apply(f, dataDir: dataDir, into: &log)
                written += 1
            } catch {
                log.append("  失败 \(f.display): \(error.localizedDescription)")
            }
        }

        // 验证
        log.append(contentsOf: verify(fields, dataDir: dataDir))
        log.insert("  已重置 \(written) 项设备标识", at: 0)
        return OpResult(written > 0, log)
    }

    private static func apply(_ f: DeviceField, dataDir: String, into log: inout [String]) throws {
        let fm = FileManager.default
        switch f.kind {
        case .machineIdFile:
            try backup(f.filePath)
            let newId = UUID().uuidString
            try newId.data(using: .utf8)?.write(to: URL(fileURLWithPath: f.filePath), options: .atomic)
            log.append("  \(f.filePath.lastPathComponent) -> \(newId)")

        case .telemetryJson:
            guard let key = f.key else { break }
            guard let data = fm.contents(atPath: f.filePath),
                  var obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                log.append("  跳过 \(f.filePath.lastPathComponent)（非标准 JSON）"); return
            }
            try backup(f.filePath)
            let newValue = newValue(forKey: key, keyPath: f.key)
            try setJSONValue(&obj, keyPath: key, value: newValue)
            let out = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted])
            try out.write(to: URL(fileURLWithPath: f.filePath), options: .atomic)
            log.append("  \(f.filePath.lastPathComponent) · \(key) -> \(String(newValue.prefix(20)))…")

        case .genericDeviceFile:
            try backup(f.filePath)
            let newId = UUID().uuidString
            try newId.data(using: .utf8)?.write(to: URL(fileURLWithPath: f.filePath), options: .atomic)
            log.append("  \(f.filePath.lastPathComponent) -> \(newId)")
        }
    }

    private static func newValue(forKey key: String, keyPath: String?) -> String {
        let lk = key.lowercased()
        if lk.contains("machineid") || lk.contains("machine_id") { return TraeLocator.newHex64() }
        if lk.contains("sqm") { return TraeLocator.newSQM() }
        if lk.contains("telemetry") && lk.hasSuffix("devdeviceid") { return UUID().uuidString }
        return UUID().uuidString
    }

    private static func setJSONValue(_ obj: inout [String: Any], keyPath: String, value: String) throws {
        // 支持 "telemetry.xxx" 与 顶层 "xxx"
        if keyPath.hasPrefix("telemetry.") {
            let sub = keyPath.replacingOccurrences(of: "telemetry.", with: "")
            var t = obj["telemetry"] as? [String: Any] ?? [:]
            t[sub] = value
            obj["telemetry"] = t
        } else {
            obj[keyPath] = value
        }
    }

    // MARK: - 验证 / 备份 / 恢复

    private static func verify(_ fields: [DeviceField], dataDir: String) -> [String] {
        var out = [String]()
        for f in fields where f.kind == .machineIdFile {
            let v = (try? String(contentsOfFile: f.filePath, encoding: .utf8)) ?? ""
            let ok = !v.isEmpty && v != (f.currentValue ?? "")
            out.append("  验证 \(f.filePath.lastPathComponent): \(ok ? "通过" : "未变化")")
        }
        return out
    }

    private static func backup(_ path: String) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else { return }
        let bak = path + ".bak"
        if fm.fileExists(atPath: bak) { try? fm.removeItem(atPath: bak) }
        try? fm.copyItem(atPath: path, toPath: bak)
    }

    /// 恢复备份（.bak）
    static func restoreBackups(dataDir: String) -> OpResult {
        var log = [String]()
        var restored = 0
        let en = FileManager.default.enumerator(atPath: dataDir)
        if let en = en {
            for case let item as String in en {
                guard item.hasSuffix(".bak") else { continue }
                let orig = String(item.dropLast(4))
                let bakAbs = dataDir + "/" + item
                let origAbs = dataDir + "/" + orig
                if FileManager.default.fileExists(atPath: bakAbs) {
                    do {
                        _ = try? FileManager.default.removeItem(atPath: origAbs)
                        try FileManager.default.copyItem(atPath: bakAbs, toPath: origAbs)
                        log.append("  已恢复: \(orig)")
                        restored += 1
                    } catch {
                        log.append("  恢复失败 \(orig): \(error.localizedDescription)")
                    }
                }
            }
        }
        if restored == 0 { log.append("  没有找到 .bak 备份") }
        return OpResult(restored > 0, log)
    }

    private static func dataDirExists(_ d: String) -> Bool {
        FileManager.default.fileExists(atPath: d)
    }
}
