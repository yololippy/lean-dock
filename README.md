# LeanDock

独立仓库：[yololippy/lean-dock](https://github.com/yololippy/lean-dock)。

面向 M18 的原生 macOS 应用（Dock 与菜单栏入口）。使用一个 Swift 进程采集本地指标、绘制键面并通过 IOHID 控制设备。没有网页插件宿主，也不要求 Python、Node 或 VSD Craft 常驻。

本目录包含全部代码、图标、构建脚本、独立检查程序和说明，可以整体移到单独仓库维护。构建不依赖父目录或 VSD。

## 构建与启动

要求 macOS 14 或更高版本、支持 Swift 6 的 Apple Command Line Tools 或 Xcode。当前构建生成运行机器对应的架构。

```bash
cd lean-dock
./Scripts/build.sh
open dist/LeanDock.app
```

应用位于 `dist/LeanDock.app`，为本机使用进行临时签名。对外分发的 Developer ID 签名与公证不在此版本中。

首次运行创建仪表盘、备忘录两页。默认自动连接设备，并开始采集指标和更新键面。

启动自动连接或点击“连接 M18”时，应用停止原仓库安装的 `com.yololippy.streamdock.togglelights` 辅助服务、退出 VSD Craft，并清理同一用户的 VSD 插件及遗留子进程，再接管设备。未能关闭旧进程或停止服务时，不继续接管；连接控制时不改写 VSD 场景或插件文件。

点击“断开设备”或退出 LeanDock，只释放设备，不打开 VSD Craft，也不重新启动旧辅助服务。原 VSD 场景及插件文件不被改写。

Dock 和菜单栏入口可重新打开主窗口；菜单栏还可连接、切换灯光或断开设备。关闭主窗口后继续运行；“启动时连接”默认开启，“登录时启动”仍由用户选择。设备由 LeanDock 控制时，若 VSD 意外启动，会再次关闭 VSD 并重新连接设备。

## 已实现的功能

- 系统运行时间、内存占比、CPU、系统盘剩余空间、系统负载。
- 通过 IORegistry 读取整机功耗估算，5 秒缓存，不可用时显示 `--`。
- 从本地只读 SQLite 判断 Codex 运行、待确认和就绪状态；读取失败显示 `?`。
- 增量读取本地 Codex 会话 JSONL 的 5 小时、每周额度快照；每 30 秒检查新增内容，保留陈旧状态色。
- 日历、24 小时时钟、现有图标资源与状态色；原生输出 64×64 JPEG。
- 两页及更多导入页面；三个实体圆键绑定上一页、首页、下一页。
- 灯环和屏幕亮度；HAN 真正休眠、DIS 恢复；识别熄屏后的 LCD 松开事件。
- 设备上的“LED 灯环开关”只切换环灯，LCD 键面持续更新；设置窗口和菜单栏的“开关屏幕与灯环”用于整机休眠与恢复。
- 原生备忘录：新增、修改、删除、保存；切换记录和关闭窗口时保存。
- 原生待办：标题、内容、截止时间、完成状态、绝对时间倒计时与到期提示。
- 键位编辑：勾选“编辑键位”，点击某一格选择功能。
- 拖拽布局：直接拖动当前页的非空图标；拖到空位会移动，拖到已有功能的位置会交换。目标位置显示青色边框。
- 拖动不触发点击动作；拖到界面外或按 Esc 取消不修改布局。布局自动保存，并立即同步设备；便签、待办及灯光键绑定随完整键位移动。
- 第三排第二、三格显示 LeanDock 自身的驻留内存（MB）和 CPU 占用；键位编辑仍可选择其他指标。

从 0.1.0 升级时会备份并一次性迁移配置：启用启动自动连接，替换首页第三排第二、三格的 VSD 指标，保留原键位 ID、便签和待办。之后手动修改的键位和自动连接选择不会被重复迁移覆盖。

未知的原厂动作不会执行原厂插件代码。

## 数据与刷新

| 内容 | 刷新或来源 |
|---|---|
| 系统指标、Codex 状态、进程指标 | 每 2 秒采集；键面仅在值或颜色改变时重绘 |
| 时钟、待办倒计时 | 可见页每秒更新 |
| 功耗 | 每 5 秒读取 IORegistry |
| Codex 额度 | 每 30 秒增量读取；无新快照则保持旧值 |
| 日历 | 以本地日期生成，跨午夜后更新 |

首次额度扫描流式处理现有日志，之后只读新增部分；识别文件替换和截断。单行缓冲限制为 1 MiB，超大非额度记录会跳过。没有读取 `auth.json`，没有发起网络额度请求。

`AppleSmartBattery.PowerTelemetryData.SystemLoad` 和 Codex 本地库/日志结构由外部软件决定，未来可能变更；应用用未知值或陈旧提示处理失败，不将失败当作零或就绪。

## 配置与便签

应用自己的数据位于：

```text
~/Library/Application Support/LeanDock/
  config.json        布局与便签/待办的原子快照
  quota-cache.json   最近有效的额度快照
  runtime.json       当前进程、设备连接和指标诊断
  Backups/           配置迁移前的备份
```

`config.json` 顶层包含 `configuration` 与 `content`。键位 ID 和对应便签在同一个原子文件中保存，避免进程中断后出现一半新布局、一半旧数据。旧开发格式的独立配置/内容文件仍可读取。

只支持当前 M18 协议：默认 `6603:1012`，也允许 `6603:1009`。导入场景中的序列号用于匹配指定设备；同型号多台设备而未指定序列号时拒绝随意选取。

## 检查、预览与性能测量

这些命令不接管设备：

```bash
./Scripts/check.sh
dist/LeanDock.app/Contents/MacOS/LeanDock --diagnostics
dist/LeanDock.app/Contents/MacOS/LeanDock --preview /tmp/leandock-page1.png
dist/LeanDock.app/Contents/MacOS/LeanDock --preview /tmp/leandock-page2.png --page 2
dist/LeanDock.app/Contents/MacOS/LeanDock --benchmark 120 --output /tmp/leandock-memory.json
```

独立检查程序覆盖协议分包、灯光写入失败、松开事件唤醒、防止唤醒后立即关灯、帧队列容量、额度日志分段/追加/轮换、SQLite 状态、配置持久化、待办截止时间和图片缓存。它不需要 XCTest 或额外下载测试库。

`--benchmark` 使用真实采集和原生绘图，不启动图形窗口、不连接 HID。图形应用的编辑窗口、设备接管和长时间使用必须另测，不能把该命令的内存结果当作所有模式的结果。

`--connect` 可用于强制启动即接管；默认已开启启动自动连接。`--background` 仅隐藏初始主窗口，保留 Dock 和菜单栏图标。诊断与预览命令始终不连接设备。

## 维护结构

```text
Sources/LeanDockCore/
  Models.swift                可持久化配置、便签、待办和指标
  ConfigurationStore.swift    原子保存和备份
  CodexReader.swift           只读状态库、增量 JSONL
  Metrics.swift               Mach、进程、磁盘、IORegistry 指标
  Rendering.swift             有界图片缓存、原生绘图与 PNG 预览
  DeviceProtocol.swift        可离线检查的报告、灯光和输入状态机
  HIDDevice.swift             IOHID 连接、回调生命周期、串行报告
  Runtime.swift               设备队列、重连、保活、采集调度
  VendorProcesses.swift       VSD 相关进程识别与关闭
Sources/LeanDock/             AppKit 主窗口、便签/待办、Dock、菜单栏与设备连接
Sources/LeanDockChecks/       有意义的离线回归检查
Sources/CPlatform/            系统 SQLite/libproc 头文件桥接
Resources/                   App 包信息
Scripts/                     构建、检查和原生应用图标生成
```

修改设备协议或回调生命周期后运行检查，并做受控实机验证。图像事务 BAT→JPEG 分包→STP、保活和灯光全部由同一设备队列串行写入；一次最多保留当前页的最新 15 帧。采集工作在独立队列，读日志不会堵住 USB 保活。

## 当前验证范围

改动前版本的 66 项离线断言、原生 UI 编辑与保存及受控接管曾通过。0.1.0 的退出恢复行为已于 0.1.1 移除。用户已确认实物图标、圆键翻页及设备控制。

完整应用后台冷启动连接 M18 时实测 RSS 约 83 MiB；打开过编辑器后，关闭窗口仍约 121 MiB。8 小时长测、实际拔插与 Mac 睡眠回归尚未完成。详细口径及限制见 [VALIDATION.md](VALIDATION.md)。

第三方参考及许可见 `THIRD_PARTY_NOTICES.md`。
