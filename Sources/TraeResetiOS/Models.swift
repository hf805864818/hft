//
//  Models.swift
//  TraeResetiOS
//
//  数据模型：探测结果、设备标识、操作日志。
//

import Foundation

extension String {
    /// 取文件/目录路径的最后一段（NSString 实现）
    var lastPathComponent: String {
        (self as NSString).lastPathComponent
    }
}

/// 探测到的一个 Trae 容器（Bundle 或 Data）
struct TraeContainer: Identifiable, Equatable {
    let id: String                 // UUID，用于唯一标识
    let bundleId: String?           // 从 Info.plist 读到的 bundle id
    let displayName: String?        // CFBundleDisplayName / 名称
    var dataDir: String?            // 数据容器绝对路径
    var bundleDir: String?          // 代码包绝对路径

    static func == (lhs: TraeContainer, rhs: TraeContainer) -> Bool {
        lhs.id == rhs.id
    }
}

/// 一个被识别出的设备标识文件 / 字段
struct DeviceField: Identifiable {
    let id = UUID()
    let filePath: String            // 文件绝对路径
    let key: String?                // JSON 里的键（如 telemetry.devDeviceId），文件型为 nil
    let kind: Kind
    let currentValue: String?

    enum Kind {
        case machineIdFile          // 独立 machineid 文件
        case telemetryJson          // storage.json 里的 telemetry.* 字段
        case genericDeviceFile      // 其它可疑 device id 文件
    }

    var display: String {
        switch kind {
        case .machineIdFile:    return "machineid 文件"
        case .telemetryJson:    return "storage.json → \(key ?? "telemetry")"
        case .genericDeviceFile: return "device 文件"
        }
    }
}

/// 操作结果与日志
struct OpResult {
    var ok: Bool
    var lines: [String]

    init(_ ok: Bool, _ lines: [String] = []) {
        self.ok = ok
        self.lines = lines
    }

    static func err(_ msg: String) -> OpResult { OpResult(false, [msg]) }
    static func okk(_ msg: String) -> OpResult { OpResult(true, [msg]) }
}

/// 一条日志条目（UI 展示用）
struct LogEntry: Identifiable {
    let id = UUID()
    let time: Date
    let level: Level
    let text: String
    enum Level { case info, ok, warn, error }
}
