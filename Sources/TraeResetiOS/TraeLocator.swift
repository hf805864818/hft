//
//  TraeLocator.swift
//  TraeResetiOS
//
//  在取消沙盒（no-sandbox）环境下定位 iOS 版 Trae 的应用容器，
//  并探测它把"设备标识 / 登录凭证"存在哪里（沙盒文件 or 其它）。
//
//  说明：iOS 版 Trae 的 device id 机制官方未公开，因此这里采用
//  "宽匹配 + 多特征" 策略：
//   1. 遍历 Bundle 容器，按 bundle id / 名称 匹配 Trae，得到容器 UUID
//   2. 用同一 UUID 定位 Data 容器
//   3. 在 Data 容器内递归搜索 device id 特征（machineid 文件、
//      telemetry JSON 字段、UUID / 64-hex 形态的值）
//

import Foundation

enum TraeLocator {

    // 宽松匹配：bundle id 或 名称 里出现 "trae"（不区分大小写）
    static let nameNeedle = "trae"

    // 常见的可疑 bundle id 前缀（按优先级，命中即优先）
    static let knownBundleHints = [
        "com.trae", "io.trae", "app.trae", "com.tongyi", "com.doubao",
        "com.volcengine", "com.bytedance", "com.ibyte", "com.byte"
    ]

    // 数据容器 / 代码包 根目录（iOS 13+ 双路径，都尝试）
    static let bundleRoots = [
        "/var/containers/Bundle/Application",
        "/private/var/containers/Bundle/Application",
        "/var/mobile/Containers/Bundle/Application"
    ]
    static let dataRoots = [
        "/var/containers/Data/Application",
        "/private/var/mobile/Containers/Data/Application",
        "/var/mobile/Containers/Data/Application"
    ]

    // device id 相关 JSON 键
    static let deviceKeys = [
        "devDeviceId", "deviceid", "device_id", "deviceuuid",
        "machineid", "machine_id", "sqmid", "sqm_id",
        "telemetry", "installsessionid", "clientid", "clientuuid"
    ]

    /// 定位结果：所有候选 Trae 容器
    static func locate() -> [TraeContainer] {
        var found = [String: TraeContainer]() // uuid -> container

        // 1) 遍历 Bundle 容器，匹配 Trae，记录 UUID 与 bundle id
        for root in bundleRoots {
            let fm = FileManager.default
            guard let uuids = (try? fm.contentsOfDirectory(atPath: root)) ?? [] ,
                  !uuids.isEmpty else { continue }
            for uuid in uuids {
                guard isUUIDish(uuid) else { continue }
                guard let app = probeBundleInfo(in: root + "/" + uuid),
                      matchesTrae(bundleId: app.bundleId, name: app.name) else { continue }
                var c = found[uuid] ?? TraeContainer(id: uuid,
                                                     bundleId: app.bundleId,
                                                     displayName: app.name,
                                                     dataDir: nil, bundleDir: nil)
                c.bundleDir = root + "/" + uuid
                found[uuid] = c
            }
        }

        // 2) 用同一 UUID 找 Data 容器
        for root in dataRoots {
            let fm = FileManager.default
            guard let uuids = (try? fm.contentsOfDirectory(atPath: root)) ?? [] else { continue }
            for uuid in uuids {
                guard isUUIDish(uuid), found[uuid] != nil else { continue }
                found[uuid]?.dataDir = root + "/" + uuid
            }
        }

        // 3) 若一个都没按名字匹配到，退化为"有 Data 容器但 bundle 未匹配"的容器也列出
        //    （便于用户手动挑选 / 探测）
        return Array(found.values)
    }

    struct BundleInfo {
        let bundleId: String?
        let name: String?
    }

    /// 在 <bundleRoot>/<uuid>/ 下找 *.app/Info.plist
    static func probeBundleInfo(in containerPath: String) -> BundleInfo? {
        let fm = FileManager.default
        guard let entries = (try? fm.contentsOfDirectory(atPath: containerPath)) else { return nil }
        for entry in entries {
            let appPath = containerPath + "/" + entry
            let infoPath = appPath + "/Info.plist"
            if fm.fileExists(atPath: infoPath),
               let data = fm.contents(atPath: infoPath),
               let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
               let dict = plist as? [String: Any] {
                let bid = dict["CFBundleIdentifier"] as? String
                let name = (dict["CFBundleDisplayName"] as? String) ?? (dict["CFBundleName"] as? String)
                return BundleInfo(bundleId: bid, name: name)
            }
        }
        return nil
    }

    static func matchesTrae(bundleId: String?, name: String?) -> Bool {
        let bid = (bundleId?.lowercased()) ?? ""
        let nm = (name?.lowercased()) ?? ""
        if nm.contains(nameNeedle) || bid.contains(nameNeedle) { return true }
        return knownBundleHints.contains { bid.hasPrefix($0.lowercased()) }
    }

    // MARK: - 在 Data 容器内搜索 device id 特征

    /// 递归扫描 dataDir，找出所有可疑 device id 字段
    static func scanDeviceFields(in dataDir: String) -> [DeviceField] {
        var results = [DeviceField]()
        let fm = FileManager.default
        guard fm.fileExists(atPath: dataDir) else { return results }

        // 1) 显式 machineid / deviceid 独立文件
        let hitFiles: [String] = ["machineid", "machine_id", "deviceid", "device_id"]
        for file in hitFiles {
            for base in ["", "/Library", "/Documents", "/Library/Application Support"] {
                let p = dataDir + base + "/" + file
                if fm.fileExists(atPath: p), let v = try? String(contentsOfFile: p, encoding: .utf8) {
                    results.append(DeviceField(filePath: p, key: nil,
                                              kind: .machineIdFile,
                                              currentValue: v.trimmingCharacters(in: .whitespacesAndNewlines)))
                }
            }
        }

        // 2) 递归找 JSON，提取 device 键（限深 8）
        let en = FileManager.default.enumerator(
            at: URL(fileURLWithPath: dataDir),
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants])
        var depthGuard = 0
        while let url = en?.nextObject() as? URL {
            depthGuard += 1
            if depthGuard > 4000 { break } // 保险
            let path = url.path
            if path.lowercased().hasSuffix(".json") {
                scanJsonForDeviceKeys(at: path, into: &results)
            }
        }
        return results
    }

    private static func scanJsonForDeviceKeys(at path: String, into results: inout [DeviceField]) {
        guard let data = FileManager.default.contents(atPath: path),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let root = obj as? [String: Any] else { return }
        // 顶层 + telemetry 子层 都找
        let targets: [(String, Any)] = root.count <= 400 ? Array(root.map { ($0.key, $0.value) }) : []
        if let telemetry = root["telemetry"] as? [String: Any] {
            targets.append(contentsOf: telemetry.map { ("telemetry.\($0.key)", $0.value) })
        }
        for (k, v) in targets {
            let lk = k.lowercased()
            guard deviceKeys.contains(where: { lk == $0 || lk.contains($0) }) else { continue }
            let s = v is String ? (v as! String) : "\(v)"
            guard !s.isEmpty, s != "null" else { continue }
            results.append(DeviceField(filePath: path, key: k, kind: .telemetryJson, currentValue: s))
        }
    }

    // MARK: - 辅助

    static func isUUIDish(_ s: String) -> Bool {
        s.count == 36 && s.filter { $0 == "-" }.count == 4
    }

    /// 重新生成 64 位十六进制（telemetry.machineId 形态）
    static func newHex64() -> String {
        (0..<64).map { _ in "0123456789abcdef"[Int.random(in: 0..<16)] }.joined()
    }
    /// 重新生成 SQM GUID {XXXXXXXX-...} 形态
    static func newSQM() -> String { "{" + UUID().uuidString.uppercased() + "}" }
}
