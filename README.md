# TraeReset iOS（越狱版）

在 **越狱 iOS** 设备上重置 **Trae（TRAE）移动端** 的设备标识 / 清除本地登录凭证，
解决「设备数量已达上限」等因本地设备 ID 累积导致的登录问题。

> 桌面版参考：[WGHCWC/TraeReset](https://github.com/WGHCWC/TraeReset)（Windows/macOS/Linux）
> 本项目是 **iOS 移植 + 越狱增强版**，由两个组件构成：
> - **iOS App**（TrollStore 安装，带 `no-sandbox` 权限）：图形化探测 + 一键重置本地文件
> - **越狱终端脚本** `trae_cli.sh`：root 运行，额外覆盖 Keychain / 系统容器等 App 碰不到的位置

---

## ⚠️ 先分清你到底卡在哪（关键）

Trae 的"限制"有**两种**，本工具只对第一种有效：

| 提示 | 本质 | 本工具能否解决 |
|------|------|----------------|
| **设备数量已达上限**（换设备登不上） | 设备维度，服务端认本地 device id | ✅ 能（重置 device id） |
| **登录次数/额度已用尽、次日再试、请稍后** | 账号维度：试用版 AI 调用 429 额度 / 服务端风控 24h 锁定 | ❌ 不能（锁的是账号，改本地没用，只能等重置 / 换号 / 升级订阅） |

官方文档明确「**登录功能本身没有次数限制**」，试用版的"次数限制"其实是每日 **AI 调用 Token 额度**（超出返回 429，次日重置）。

**如果你的提示是后者，任何本地工具（包括本项目）都无法解决。** 先确认再使用。

---

## 前提

1. **iOS 14 – 17.0**（部分 16.7 RC）设备，已安装 **TrollStore**（巨魔）。
   - 或使用 **Relaxin**（RootHide 越狱，A12–A17，iOS 16.5–18.7.1 / 26.0–26.0.1）+ 越狱终端。
2. 使用本工具产生的一切后果由使用者自行承担，仅供个人学习与技术研究。

---

## 用法 A：TrollStore App（推荐先试）

App 以 `no-sandbox` entitlement 安装后，可直接访问 Trae 的应用沙盒文件。

1. 构建 IPA（见下文）。
2. 用 TrollStore 打开 `TraeResetiOS-TrollStore.ipa` 安装。
   - 安装时 TrollStore 会**保留 app 内嵌的 entitlements**（含 `no-sandbox`）。
   - 若装完无法访问其它 App 数据，可在 TrollStore 里对该 App 重新 fakesign 带 entitlements。
3. 打开 App → 选择检测到的 Trae 容器 → 查看 device id → 一键重置 / 清除凭证。
4. 重开 Trae 重新登录。

> App 只处理**文件型**数据。若 App 探测不到 device id（提示"未检测到"），说明 iOS 版 Trae 把它存在 **Keychain 或 服务端**，请转用法 B。

## 用法 B：越狱终端脚本（root）

覆盖 App 碰不到的位置（系统容器 / Keychain 周边）：

```sh
# 上传到手机（iSH/SFTP 越狱终端/SiriusCydia 等方式）后：
sudo sh trae_cli.sh probe     # 探测（安全，无副作用）
sudo sh trae_cli.sh reset     # 重置 device id + 清凭证（自动备份 .bak）
sudo sh trae_cli.sh restore   # 恢复备份
```

先 `probe` 看清楚 iOS 版 Trae 把 device id 存哪，再决定 `reset`。

---

## 构建

### 方式 1：GitHub Actions（无需本机 Mac）
1. 把本仓库推到 GitHub。
2. 推到 `main` 或手动触发 **Build TrollStore IPA** workflow。
3. 在 Actions 页面下载 artifact `TraeResetiOS-TrollStore`（即 .ipa）。

### 方式 2：本地 macOS（Xcode + xcodegen）
```sh
brew install xcodegen
bash Scripts/build_ipa.sh
# 产物: TraeResetiOS-TrollStore.ipa
```

构建流程：`xcodegen` 生成工程 → `xcodebuild` 编译 → `codesign` ad-hoc 重签并嵌入
`no-sandbox` entitlements → 打包成标准 `Payload/` IPA。

---

## 原理

- 桌面版 Trae 在本地存 `machineid`（UUID）与 `storage.json` 的
  `telemetry.machineId / devDeviceId / sqmId`。重置它们 = 让服务端把你当新设备。
- **iOS 版 Trae 的 device id 机制官方未公开**，本项目采用「宽匹配 + 多特征探测」：
  定位 Trae 沙盒 → 扫描 `machineid` 文件、JSON 里的 `telemetry.*` / device 键 → 重新生成 → 验证。
- 若 iOS 版改用 **Keychain / `identifierForVendor` / 服务端账号绑定**，本地文件重置无效，
  需越狱终端处理 Keychain，或只能等服务端额度/风控解除。

---

## 免责声明

本工具仅供个人学习与技术研究使用，请勿用于商业或非法用途。
使用本工具产生的一切后果由使用者自行承担，与作者无关。
本工具不修改 Trae 软件本体，仅操作本地用户数据文件。
