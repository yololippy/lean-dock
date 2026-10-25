import AppKit
import Foundation
import LeanDockCore
import ServiceManagement

@MainActor
func runLeanDock() {
    do {
        if try runDiagnostics() { return }
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let coordinator = try ApplicationCoordinator()
        app.delegate = coordinator
        withExtendedLifetime(coordinator) { app.run() }
    } catch {
        if CommandLine.arguments.count > 1 {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8)); exit(1)
        }
        let alert = NSAlert(); alert.messageText = "LeanDock 无法启动"; alert.informativeText = error.localizedDescription
        alert.runModal()
    }
}

private func initialState(store: ConfigurationStore) throws -> (AppConfiguration, UserContent, [String]) {
    if let config = try store.loadConfiguration() { return (config.applyingNativeDefaults(), try store.loadContent(), []) }
    if let profile = try? VSDImporter.currentProfile() {
        let imported = try VSDImporter.read(profile: profile)
        return (imported.configuration.applyingNativeDefaults(), imported.content, imported.warnings)
    }
    return (AppConfiguration.standard.applyingNativeDefaults(), .init(), [])
}

/// Read-only diagnostics never initialize HID or terminate another application.
private func runDiagnostics() throws -> Bool {
    let args = CommandLine.arguments
    if args.contains("--help") {
        print("""
        LeanDock — 原生 M18 控制器
          --preview /absolute/path.png [--page 1]   生成真实数据键面预览，不连接设备
          --diagnostics                            输出本地指标，不连接设备
          --benchmark 60 --output /path.json       真实采集与绘图的有限时长测量
          --background                             不打开初始窗口，保留 Dock 和菜单栏图标
          --connect                                启动后连接设备（退出 VSD 并暂停旧辅助服务）
        默认启动自动连接设备；配置存放在 ~/Library/Application Support/LeanDock。
        """)
        return true
    }
    guard args.contains("--preview") || args.contains("--diagnostics") || args.contains("--benchmark") else { return false }
    func argument(_ flag: String) throws -> String {
        guard let index = args.firstIndex(of: flag), args.indices.contains(index + 1) else { throw LeanDockError.message("缺少 \(flag) 参数。") }
        return args[index + 1]
    }
    let store = ConfigurationStore(), (config, content, _) = try initialState(store: store)
    // Diagnostic collection does not persist caches or app configuration.
    let collector = MetricCollector(), renderer = KeyRenderer()
    if args.contains("--diagnostics") {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try encoder.encode(collector.collect()), as: UTF8.self)); return true
    }
    let page = args.contains("--page") ? max(0, min(config.pages.count - 1, (Int(try argument("--page")) ?? 1) - 1)) : 0
    let keys = config.pages[page].keys
    if args.contains("--preview") {
        let snapshot = collector.collect()
        let frames = try keys.map { try renderer.render(key: $0, face: KeyRenderer.face(for: $0, snapshot: snapshot, content: content)) }
        try KeyRenderer.preview(frames: frames, at: URL(fileURLWithPath: try argument("--preview")))
        print("预览已生成；未连接设备。"); return true
    }
    guard let seconds = Int(try argument("--benchmark")), (1...28800).contains(seconds) else { throw LeanDockError.message("测量时长需在 1–28800 秒之间。") }
    var samples: [MetricSnapshot] = []
    let start = Date()
    for tick in 0...seconds {
        try autoreleasepool {
            let snapshot = collector.collect()
            for key in keys { _ = try renderer.render(key: key, face: KeyRenderer.face(for: key, snapshot: snapshot, content: content)) }
            if tick % 10 == 0 || tick == seconds { samples.append(snapshot) }
        }
        if tick < seconds { Thread.sleep(until: start.addingTimeInterval(Double(tick + 1))) }
    }
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(samples)
    if args.contains("--output") { try data.write(to: URL(fileURLWithPath: try argument("--output")), options: .atomic) }
    else { print(String(decoding: data, as: UTF8.self)) }
    print("完成 \(seconds) 秒原生采集与绘图；编码 \(renderer.encodedFrames) 帧，缓存 \(renderer.cachedBytes) 字节；未连接设备。")
    return true
}

@MainActor
final class ApplicationCoordinator: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let store: ConfigurationStore
    var configuration: AppConfiguration
    var content: UserContent
    var warnings: [String]
    let engine = DeckEngine()
    var sampler: SamplingLoop!
    var snapshot = MetricSnapshot()
    var deviceStatus = DeviceStatus()
    var frames: [Data] = []
    var page = 0
    var statusItem: NSStatusItem!
    var mainWindow: NSWindow?
    var keyButtons: [NSButton] = []
    var keyLabels: [NSTextField] = []
    var lastImages: [Data] = []
    var pagePicker: NSPopUpButton?
    var statusLabel: NSTextField?
    var memoryLabel: NSTextField?
    var detailLabel: NSTextField?
    var connectButton: NSButton?
    var editMode = false
    let dragScope = UUID().uuidString
    var editingCheckbox: NSButton?
    var notesWindows: [String: NotesWindowController] = [:]
    var todoWindows: [String: TodoWindowController] = [:]
    var ownsSession = false
    var switching = false
    var terminating = false
    var observers: [NSObjectProtocol] = []
    var lastDiagnosticsWrite = Date.distantPast

    init(store: ConfigurationStore = .init()) throws {
        self.store = store
        let state = try initialState(store: store)
        configuration = state.0; content = state.1; warnings = state.2
        super.init()
        if try store.loadConfiguration() != configuration {
            if FileManager.default.fileExists(atPath: store.configURL.path) { try store.backup() }
            try store.save(configuration: configuration, content: content)
        }
        sampler = SamplingLoop(configuration: configuration, content: content, cacheDirectory: store.directory)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMenu()
        engine.onStatus = { [weak self] status in DispatchQueue.main.async {
            guard let self else { return }; self.deviceStatus = status; self.refreshUI(); self.writeRuntime(force: true)
        } }
        engine.onActivate = { [weak self] position in DispatchQueue.main.async { self?.activate(position) } }
        sampler.onUpdate = { [weak self] snapshot, frames, pageID, keys in DispatchQueue.main.async {
            guard let self, self.configuration.pages[self.page].id == pageID,
                  self.configuration.pages[self.page].keys == keys else { return }
            self.snapshot = snapshot; self.frames = frames; self.engine.updateFrames(frames); self.refreshUI(); self.writeRuntime()
        } }
        sampler.onError = { [weak self] message in DispatchQueue.main.async { self?.showError(message) } }
        sampler.start(); updateSampling()
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.engine.disconnect() }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if let self, self.ownsSession {
                self.engine.connect(self.configuration.device)
            } }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      app.bundleIdentifier == "com.mirabox.streamdock", self.ownsSession, !self.switching else { return }
                self.connectDevice()
            }
        })
        if !CommandLine.arguments.contains("--background") { showDashboard() }
        if configuration.connectOnLaunch || CommandLine.arguments.contains("--connect") { connectDevice() }
    }

    func installMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "square.grid.3x3.fill", accessibilityDescription: "LeanDock")
        let menu = NSMenu()
        for (title, action) in [("打开 LeanDock", #selector(showDashboard)), ("连接 M18", #selector(connectDevice)),
                                ("切换灯光", #selector(toggleLights)), ("断开设备", #selector(disconnectDevice)),
                                ("退出 LeanDock", #selector(quit))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: ""); item.target = self; menu.addItem(item)
        }
        statusItem.menu = menu
        let main = NSMenu(), appItem = NSMenuItem(), appMenu = NSMenu()
        let quitItem = NSMenuItem(title: "退出 LeanDock", action: #selector(quit), keyEquivalent: "q"); quitItem.target = self
        appMenu.addItem(quitItem); appItem.submenu = appMenu; main.addItem(appItem)
        let editItem = NSMenuItem(), edit = NSMenu(title: "编辑")
        for (title, selector, key) in [("撤销", Selector(("undo:")), "z"), ("剪切", #selector(NSText.cut(_:)), "x"),
                                       ("复制", #selector(NSText.copy(_:)), "c"), ("粘贴", #selector(NSText.paste(_:)), "v"),
                                       ("全选", #selector(NSText.selectAll(_:)), "a")] {
            edit.addItem(withTitle: title, action: selector, keyEquivalent: key)
        }
        editItem.submenu = edit; main.addItem(editItem); NSApplication.shared.mainMenu = main
        let windowItem = NSMenuItem(), windowMenu = NSMenu(title: "窗口")
        windowMenu.addItem(withTitle: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu; main.addItem(windowItem); NSApplication.shared.windowsMenu = windowMenu
    }

    @objc func showDashboard() {
        if mainWindow == nil { buildDashboard() }
        mainWindow?.makeKeyAndOrderFront(nil); NSApplication.shared.activate(ignoringOtherApps: true); refreshUI()
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showDashboard(); return true
    }
    func windowWillClose(_ notification: Notification) {
        if (notification.object as? NSWindow) === mainWindow {
            mainWindow = nil; keyButtons.removeAll(); keyLabels.removeAll(); lastImages.removeAll()
            pagePicker = nil; statusLabel = nil; memoryLabel = nil; detailLabel = nil; connectButton = nil; editingCheckbox = nil
        }
    }
    func buildDashboard() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 884, height: 694),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "LeanDock"; window.isReleasedWhenClosed = false; window.delegate = self; window.center()
        window.appearance = NSAppearance(named: .darkAqua)
        let root = NSStackView(); root.orientation = .horizontal; root.alignment = .top; root.spacing = 26
        root.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(root)
        NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 24),
                                     root.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -24),
                                     root.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 24),
                                     root.bottomAnchor.constraint(lessThanOrEqualTo: window.contentView!.bottomAnchor, constant: -20)])
        let left = stack(spacing: 16), right = stack(spacing: 8)
        left.widthAnchor.constraint(equalToConstant: 546).isActive = true; right.widthAnchor.constraint(equalToConstant: 260).isActive = true
        root.addArrangedSubview(left); root.addArrangedSubview(right)
        left.addArrangedSubview(label("LeanDock", size: 29, bold: true))
        left.addArrangedSubview(label("你的 M18，原生运行。", size: 13, secondary: true))
        let picker = NSPopUpButton(); picker.addItems(withTitles: configuration.pages.map(\.name)); picker.selectItem(at: page)
        picker.target = self; picker.action = #selector(changePage(_:)); pagePicker = picker; left.addArrangedSubview(picker)
        var rows: [[NSView]] = []
        keyButtons.removeAll(); keyLabels.removeAll(); lastImages.removeAll()
        for row in 0..<3 {
            var cells: [NSView] = []
            for column in 0..<5 {
                let index = row * 5 + column, cell = stack(spacing: 5)
                cell.alignment = .centerX
                let button = DeckKeyButton(); button.tag = index; button.target = self; button.action = #selector(keyPressed(_:))
                button.dragScope = dragScope
                button.payload = { [weak self] in
                    guard let self else { return nil }
                    let current = self.configuration.pages[self.page], key = current.keys[index]
                    return key.kind == .empty ? nil : .init(pageID: current.id, keyID: key.id)
                }
                button.acceptsMove = { [weak self] payload in self?.canMoveKey(payload, to: index) == true }
                button.onMove = { [weak self] payload in self?.moveKey(payload, to: index) == true }
                button.title = ""; button.imagePosition = .imageOnly
                button.isBordered = false; button.imageScaling = .scaleProportionallyUpOrDown
                button.wantsLayer = true; button.layer?.cornerRadius = 12; button.layer?.borderWidth = 1
                button.layer?.borderColor = NSColor.white.withAlphaComponent(0.13).cgColor
                button.layer?.backgroundColor = NSColor(calibratedWhite: 0.12, alpha: 1).cgColor
                button.widthAnchor.constraint(equalToConstant: 96).isActive = true; button.heightAnchor.constraint(equalToConstant: 96).isActive = true
                let caption = label("", size: 10, secondary: true); caption.alignment = .center
                cell.addArrangedSubview(button); cell.addArrangedSubview(caption); cells.append(cell)
                keyButtons.append(button); keyLabels.append(caption)
            }
            rows.append(cells)
        }
        let grid = NSGridView(views: rows); grid.columnSpacing = 14; grid.rowSpacing = 12; left.addArrangedSubview(grid)
        let navigation = NSStackView(); navigation.orientation = .horizontal; navigation.spacing = 12
        for (text, tag) in [("← 上一页", 15), ("⌂ 首页", 16), ("下一页 →", 17)] {
            let button = NSButton(title: text, target: self, action: #selector(keyPressed(_:))); button.tag = tag
            button.bezelStyle = .rounded; navigation.addArrangedSubview(button)
        }
        left.addArrangedSubview(navigation)
        let edit = NSButton(checkboxWithTitle: "编辑键位（点击图标选择功能）", target: self, action: #selector(toggleEditing(_:)))
        edit.state = editMode ? .on : .off; editingCheckbox = edit; left.addArrangedSubview(edit)
        left.addArrangedSubview(label("拖动图标调整位置；拖到已有功能时交换。", size: 11, secondary: true))
        left.addArrangedSubview(label("关闭此窗口后，菜单栏和设备功能继续运行。", size: 11, secondary: true))

        right.addArrangedSubview(label("设备", size: 17, bold: true))
        right.addArrangedSubview(label(String(format: "M18 · %04X:%04X", configuration.device.vendorID, configuration.device.productID), size: 12, secondary: true))
        let state = label("", size: 12); state.maximumNumberOfLines = 4; statusLabel = state; right.addArrangedSubview(state)
        let connect = NSButton(title: "连接 M18", target: self, action: #selector(connectDevice)); connect.bezelStyle = .rounded
        connect.bezelColor = NSColor.systemTeal; connectButton = connect; right.addArrangedSubview(connect)
        right.addArrangedSubview(NSButton(title: "开关屏幕与灯环", target: self, action: #selector(toggleLights)))
        right.addArrangedSubview(NSButton(title: "断开设备", target: self, action: #selector(disconnectDevice)))
        right.addArrangedSubview(separator())
        right.addArrangedSubview(label("运行状态", size: 17, bold: true))
        let memory = label("采集本地数据…", size: 12)
        memory.toolTip = "内存用量使用系统 physical footprint；驻留内存是 RSS，包含共享映射。"
        memoryLabel = memory; right.addArrangedSubview(memory)
        let detail = label("", size: 11, secondary: true); detail.maximumNumberOfLines = 4; detailLabel = detail; right.addArrangedSubview(detail)
        right.addArrangedSubview(separator())
        right.addArrangedSubview(label("亮度", size: 17, bold: true))
        for (text, value, tag) in [("屏幕", configuration.device.screenBrightness, 0), ("灯环", configuration.device.ringBrightness, 1)] {
            right.addArrangedSubview(label(text, size: 11, secondary: true))
            let slider = NSSlider(value: Double(value), minValue: tag == 0 ? 1 : 0, maxValue: 100, target: self, action: #selector(brightnessChanged(_:)))
            slider.tag = tag; slider.isContinuous = false; slider.widthAnchor.constraint(equalToConstant: 235).isActive = true; right.addArrangedSubview(slider)
        }
        let auto = NSButton(checkboxWithTitle: "启动时连接设备", target: self, action: #selector(autoConnectChanged(_:)))
        auto.state = configuration.connectOnLaunch ? .on : .off; right.addArrangedSubview(auto)
        let login = NSButton(checkboxWithTitle: "登录时启动 LeanDock", target: self, action: #selector(loginChanged(_:)))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off; right.addArrangedSubview(login)
        right.addArrangedSubview(NSButton(title: "重新导入 VSD 两页配置…", target: self, action: #selector(importVendor)))
        mainWindow = window
    }

    func stack(spacing: CGFloat) -> NSStackView {
        let view = NSStackView(); view.orientation = .vertical; view.alignment = .leading; view.spacing = spacing; return view
    }
    func label(_ text: String, size: CGFloat, bold: Bool = false, secondary: Bool = false) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text); field.font = .systemFont(ofSize: size, weight: bold ? .semibold : .regular)
        field.textColor = secondary ? .secondaryLabelColor : .labelColor; field.isSelectable = false; return field
    }
    func separator() -> NSBox { let view = NSBox(); view.boxType = .separator; view.widthAnchor.constraint(equalToConstant: 245).isActive = true; return view }

    func refreshUI() {
        statusLabel?.stringValue = switching ? "正在切换设备控制…" : deviceStatus.message
        connectButton?.isEnabled = !switching && !deviceStatus.connected
        connectButton?.title = deviceStatus.connected ? "M18 已连接" : "连接 M18"
        memoryLabel?.stringValue = String(format: "内存用量  %.1f MiB\n驻留内存  %.1f MiB", Double(snapshot.footprintBytes) / 1048576, Double(snapshot.residentBytes) / 1048576)
        let date = snapshot.quotaUpdatedAt.map { "额度快照：\($0.prefix(19))" } ?? "额度：等待本地快照"
        detailLabel?.stringValue = ([date] + warnings + snapshot.warnings).joined(separator: "\n")
        pagePicker?.selectItem(at: page)
        let keys = configuration.pages[page].keys
        for index in keyButtons.indices {
            keyLabels[index].stringValue = keys[index].kind == .empty ? "" : keys[index].kind.title
            keyButtons[index].setAccessibilityLabel(keys[index].kind.title)
            let action = editMode ? "点击编辑：\(keys[index].kind.title)" : keys[index].label.isEmpty ? keys[index].kind.title : keys[index].label
            keyButtons[index].toolTip = action + (keys[index].kind == .empty ? "\n可将图标拖入此处" : "\n拖动调整位置；拖到已有功能时交换")
            if frames.count == 15, lastImages.count != 15 || lastImages[index] != frames[index] { keyButtons[index].image = NSImage(data: frames[index]) }
        }
        if frames.count == 15 { lastImages = frames }
    }
    func updateSampling() {
        sampler.update(configuration: configuration, content: content, page: page)
        engine.setLightPosition(configuration.pages[page].keys.firstIndex { $0.kind == .lights })
    }
    func canMoveKey(_ payload: DeckKeyButton.Payload, to position: Int) -> Bool {
        let current = configuration.pages[page]
        guard current.id == payload.pageID, current.keys.indices.contains(position),
              let source = current.keys.firstIndex(where: { $0.id == payload.keyID }) else { return false }
        return source != position && current.keys[source].kind != .empty
    }
    func moveKey(_ payload: DeckKeyButton.Payload, to position: Int) -> Bool {
        guard canMoveKey(payload, to: position) else { return false }
        do {
            let source = configuration.pages[page].keys.firstIndex { $0.id == payload.keyID }!
            let next = try configuration.relocatingKey(id: payload.keyID, inPage: payload.pageID, to: position)
            // Persist first so a failed write leaves the visible and physical layout intact.
            try store.save(configuration: next, content: content)
            configuration = next
            if frames.count == 15 {
                frames.swapAt(source, position); lastImages.removeAll(); engine.updateFrames(frames)
            }
            updateSampling(); refreshUI()
            return true
        } catch {
            DispatchQueue.main.async { [weak self] in self?.showError(error.localizedDescription) }
            return false
        }
    }
    @objc func changePage(_ sender: NSPopUpButton) { page = sender.indexOfSelectedItem; updateSampling(); refreshUI() }
    @objc func keyPressed(_ sender: NSButton) {
        if editMode && sender.tag < 15 { editKey(sender.tag) } else { activate(sender.tag) }
    }
    @objc func toggleEditing(_ sender: NSButton) { editMode = sender.state == .on; refreshUI() }
    func activate(_ position: Int) {
        if position == 15 { page = (page - 1 + configuration.pages.count) % configuration.pages.count; updateSampling(); refreshUI(); return }
        if position == 16 { page = 0; updateSampling(); refreshUI(); return }
        if position == 17 { page = (page + 1) % configuration.pages.count; updateSampling(); refreshUI(); return }
        guard (0..<15).contains(position) else { return }
        let key = configuration.pages[page].keys[position]
        switch key.kind {
        case .lights: toggleLights()
        case .notes: openNotes(key)
        case .todo: openTodo(key)
        case .unsupported: showError("此原厂动作尚未实现：\(key.label)\n\(key.originalUUID ?? "")")
        default: break
        }
    }
    func editKey(_ position: Int) {
        let key = configuration.pages[page].keys[position]
        let alert = NSAlert(); alert.messageText = "编辑第 \(position + 1) 个键"; alert.addButton(withTitle: "保存"); alert.addButton(withTitle: "取消")
        let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 250, height: 28))
        let kinds = KeyKind.allCases.filter { $0 != .unsupported }; picker.addItems(withTitles: kinds.map(\.title))
        picker.selectItem(at: kinds.firstIndex(of: key.kind) ?? 0); alert.accessoryView = picker
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        var next = configuration; next.pages[page].keys[position].kind = kinds[picker.indexOfSelectedItem]
        next.pages[page].keys[position].label = kinds[picker.indexOfSelectedItem].title
        do { try store.save(next); configuration = next; updateSampling(); refreshUI() } catch { showError(error.localizedDescription) }
    }
    @objc func toggleLights() { engine.toggleLights() }
    @objc func brightnessChanged(_ sender: NSSlider) {
        var next = configuration
        if sender.tag == 0 { next.device.screenBrightness = sender.integerValue } else { next.device.ringBrightness = sender.integerValue }
        do { try store.save(next); configuration = next; engine.setBrightness(screen: next.device.screenBrightness, ring: next.device.ringBrightness) }
        catch { showError(error.localizedDescription) }
    }
    @objc func autoConnectChanged(_ sender: NSButton) {
        var next = configuration; next.connectOnLaunch = sender.state == .on
        do { try store.save(next); configuration = next } catch { sender.state = configuration.connectOnLaunch ? .on : .off; showError(error.localizedDescription) }
    }
    @objc func loginChanged(_ sender: NSButton) {
        do { if sender.state == .on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
        catch { sender.state = SMAppService.mainApp.status == .enabled ? .on : .off; showError(error.localizedDescription) }
    }
    @objc func importVendor() {
        let alert = NSAlert(); alert.messageText = "重新导入当前 VSD 场景？"
        alert.informativeText = "LeanDock 当前配置和便签会先保存到备份目录，再用 VSD 场景重建。"
        alert.addButton(withTitle: "备份并导入"); alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        for controller in Array(notesWindows.values) { guard controller.flush() else { return }; controller.close() }
        for controller in Array(todoWindows.values) { guard controller.flush() else { return }; controller.close() }
        do {
            let result = try VSDImporter.read(profile: VSDImporter.currentProfile())
            let imported = result.configuration.applyingNativeDefaults()
            try store.backup(); try store.save(configuration: imported, content: result.content)
            configuration = imported; content = result.content; warnings = result.warnings; page = 0
            pagePicker?.removeAllItems(); pagePicker?.addItems(withTitles: configuration.pages.map(\.name)); updateSampling(); refreshUI()
        } catch { showError(error.localizedDescription) }
    }
    func writeRuntime(force: Bool = false) {
        guard force || Date().timeIntervalSince(lastDiagnosticsWrite) >= 5 else { return }; lastDiagnosticsWrite = Date()
        struct RuntimeReport: Encodable { var pid: Int32; var updatedAt: Date; var device: DeviceStatus; var metrics: MetricSnapshot; var page: Int }
        let report = RuntimeReport(pid: getpid(), updatedAt: Date(), device: deviceStatus, metrics: snapshot, page: page + 1)
        if let data = try? JSONEncoder().encode(report) { try? data.write(to: store.directory.appendingPathComponent("runtime.json"), options: .atomic) }
    }
    func showError(_ message: String) { let alert = NSAlert(); alert.messageText = "LeanDock"; alert.informativeText = message; alert.runModal() }
    @objc func quit() { NSApplication.shared.terminate(nil) }
}
