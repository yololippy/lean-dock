import AppKit
import Foundation
import LeanDockCore

extension ApplicationCoordinator {
    @objc func connectDevice() {
        guard !switching else { return }
        switching = true; refreshUI()
        Task { @MainActor in
            do {
                await disconnectSession()
                // Stop KeepAlive before terminating any remaining vendor/plugin processes.
                let service = "gui/\(getuid())/com.yololippy.streamdock.togglelights"
                let helperStopped = await Task.detached { () -> Bool in
                    if Self.launchctl(["print", service]) != 0 { return true }
                    return Self.launchctl(["bootout", service]) == 0
                }.value
                guard helperStopped else { throw LeanDockError.message("旧灯光辅助服务尚未停止，未接管 M18。") }
                for app in NSRunningApplication.runningApplications(withBundleIdentifier: "com.mirabox.streamdock") {
                    _ = app.terminate()
                }
                // Allow normal shutdown, then terminate orphan vendor helpers by their own paths.
                for _ in 0..<30 {
                    if NSRunningApplication.runningApplications(withBundleIdentifier: "com.mirabox.streamdock").isEmpty { break }
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
                try await Task.detached { try VendorProcesses.stopAll() }.value
                ownsSession = true; switching = false; engine.connect(configuration.device); updateSampling(); refreshUI()
            } catch {
                await disconnectSession(); switching = false; refreshUI(); showError(error.localizedDescription)
            }
        }
    }

    @objc func disconnectDevice() {
        guard !switching else { return }; switching = true; refreshUI()
        Task { @MainActor in await disconnectSession(); switching = false; refreshUI() }
    }
    func disconnectSession() async {
        ownsSession = false
        if deviceStatus.connected { engine.wake() }
        await withCheckedContinuation { continuation in engine.disconnect { continuation.resume() } }
    }

    nonisolated static func launchctl(_ arguments: [String]) -> Int32 {
        let task = Process(); task.executableURL = URL(fileURLWithPath: "/bin/launchctl"); task.arguments = arguments
        task.standardOutput = FileHandle.nullDevice; task.standardError = FileHandle.nullDevice
        do { try task.run(); task.waitUntilExit(); return task.terminationStatus } catch { return -1 }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if terminating { return .terminateNow }
        for controller in notesWindows.values where !controller.flush() { return .terminateCancel }
        for controller in todoWindows.values where !controller.flush() { return .terminateCancel }
        terminating = true; sampler.stop()
        Task { @MainActor in
            await disconnectSession()
            NSApplication.shared.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func openNotes(_ key: KeyConfiguration) {
        if let existing = notesWindows[key.id] { existing.showWindow(nil); NSApplication.shared.activate(ignoringOtherApps: true); return }
        let controller = NotesWindowController(notes: content.notes[key.id] ?? [])
        controller.onSave = { [weak self] notes in
            guard let self else { return }; var next = self.content; next.notes[key.id] = notes
            try self.store.save(next); self.content = next; self.updateSampling()
        }
        controller.onClose = { [weak self] in self?.notesWindows.removeValue(forKey: key.id) }
        notesWindows[key.id] = controller; controller.showWindow(nil); NSApplication.shared.activate(ignoringOtherApps: true)
    }
    func openTodo(_ key: KeyConfiguration) {
        if let existing = todoWindows[key.id] { existing.showWindow(nil); NSApplication.shared.activate(ignoringOtherApps: true); return }
        let controller = TodoWindowController(todo: content.todos[key.id] ?? Todo())
        controller.onSave = { [weak self] todo in
            guard let self else { return }; var next = self.content; next.todos[key.id] = todo
            try self.store.save(next); self.content = next; self.updateSampling()
        }
        controller.onClose = { [weak self] in self?.todoWindows.removeValue(forKey: key.id) }
        todoWindows[key.id] = controller; controller.showWindow(nil); NSApplication.shared.activate(ignoringOtherApps: true)
    }
}
