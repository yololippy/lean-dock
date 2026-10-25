import Foundation
import LeanDockCore
import CPlatform
import ImageIO

var checks = 0
func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    checks += 1
    if try !condition() { throw LeanDockError.message(message) }
}

func json(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) }
func quotaLine(_ used: Double, timestamp: String = "2026-10-25T10:00:00Z") throws -> Data {
    var data = try json(["type": "event_msg", "timestamp": timestamp, "payload": ["type": "token_count", "rate_limits": ["primary": ["used_percent": used], "secondary": ["used_percent": 5]]]])
    data.append(10); return data
}
func report(_ code: UInt8, _ down: Bool) -> Data { Data([0x41,0x43,0x4b,0,0,0x4f,0x4b,0,0,code,down ? 1 : 0]) }
func run() throws {
    let temp = FileManager.default.temporaryDirectory.appendingPathComponent("LeanDockChecks-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temp) }

    try require(M18Protocol.mode.count == 1024 && M18Protocol.mode.prefix(11) == Data([0x43,0x52,0x54,0,0,0x4d,0x4f,0x44,0,0,0x33]), "Software mode packet")
    let jpeg = Data((0..<2500).map { UInt8($0 % 251) })
    let packets = try M18Protocol.imagePackets(position: 0, jpeg: jpeg)
    try require(packets.count == 5 && packets.allSatisfy { $0.count == 1024 }, "Image transaction packet sizes")
    try require(packets[0][12] == 11, "Top-left image is hardware slot 11")
    try require(packets[0].subdata(in: 8..<12) == Data([0,0,9,196]), "JPEG byte length must be big endian")
    try require(Data(packets.dropFirst().dropLast().flatMap { $0 }).prefix(jpeg.count) == jpeg, "JPEG packet payload roundtrip")
    try require(packets.last!.prefix(8) == Data([0x43,0x52,0x54,0,0,0x53,0x54,0x50]), "Image transaction ends with STP")
    do { _ = try M18Protocol.imagePackets(position: 15, jpeg: jpeg); throw LeanDockError.message("Non-LCD image write accepted") }
    catch let error as LeanDockError { try require(error.localizedDescription.contains("无效"), "Reject circular-button image writes") }
    try require(M18Protocol.input(report(0x25, false))?.position == 15, "Left round button")
    try require(M18Protocol.input(report(0x30, false))?.position == 16, "Home round button")
    try require(M18Protocol.input(report(0x31, false))?.position == 17, "Right round button")
    try require(M18Protocol.input(Data([0x41,0x43])) == nil && M18Protocol.input(report(0xff, false)) == nil, "Ignore malformed input")

    var gate = InputGate()
    try require(gate.accept(.init(position: 14, isDown: false), asleep: true, lightPosition: 14, now: 1) == .wake, "Wake from a release-only LCD report")
    try require(gate.accept(.init(position: 14, isDown: false), asleep: false, lightPosition: 14, now: 1.1) == .none, "Wake cannot immediately toggle off")
    try require(gate.accept(.init(position: 15, isDown: false), asleep: true, lightPosition: 14, now: 2) == .none, "Round button does not invent a sleep wake event")
    try require(gate.accept(.init(position: 14, isDown: true), asleep: true, lightPosition: 14, now: 3) == .wake, "Wake from key-down")
    try require(gate.accept(.init(position: 14, isDown: false), asleep: false, lightPosition: 14, now: 4) == .none, "Consume the release of a wake press even after a long hold")
    try require(gate.accept(.init(position: 14, isDown: false), asleep: false, lightPosition: 14, now: 5) == .activate(14), "Next ordinary press remains functional")

    var lights = LightingController(), writes: [Data] = []
    try lights.apply(on: false, config: .init()) { writes.append($0) }
    try require(lights.state == .asleep && writes == [M18Protocol.ring(0), M18Protocol.verb("HAN")], "True screen and ring off ordering")
    var attempts = 0
    do { try lights.apply(on: true, config: .init()) { _ in attempts += 1; if attempts == 2 { throw LeanDockError.message("injected write failure") } } }
    catch { }
    try require(lights.state == .unknown, "Partial lighting failure cannot be reported as successfully awake")
    writes.removeAll(); try lights.apply(on: true, config: .init()) { writes.append($0) }
    try require(lights.state == .awake && writes == [M18Protocol.verb("DIS"), M18Protocol.brightness(25), M18Protocol.ring(100)], "Wake restores brightness and ring")
    var buffer = LatestFrameBuffer()
    for i in 0..<1000 { buffer.replace(Array(repeating: Data([UInt8(i % 251)]), count: 15)) }
    try require(buffer.count == 15 && buffer.take()?.first == Data([UInt8(999 % 251)]) && buffer.count == 0, "Frame backlog is bounded and latest wins")

    let first = try quotaLine(30)
    var decoder = JSONLDecoder(), decoded: [Data] = []
    decoder.feed(first.prefix(11)) { decoded.append($0) }
    try require(decoded.isEmpty, "Incomplete JSONL must not be parsed")
    decoder.feed(first.dropFirst(11)) { decoded.append($0) }
    try require(decoded.count == 1 && CodexUsageReader.record(from: decoded[0])?.primaryUsed == 30, "Split JSONL record is preserved")
    decoder.maximumLineBytes = 64; decoder.feed(Data(repeating: 65, count: 200)) { _ in }
    try require(decoder.bufferedBytes <= 64, "Oversized non-quota line cannot grow memory indefinitely")
    decoder.feed(Data([10])) { _ in }; decoder.maximumLineBytes = 1_048_576
    decoder.feed(first) { decoded.append($0) }
    try require(decoded.count == 2, "Reader recovers after oversized line")
    let logs = temp.appendingPathComponent("sessions"); try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
    let log = logs.appendingPathComponent("one.jsonl"); try first.write(to: log)
    let usage = CodexUsageReader(roots: [logs]); usage.scan()
    try require(usage.latest?.primaryUsed == 30, "Initial quota scan")
    let handle = try FileHandle(forWritingTo: log); try handle.seekToEnd(); try handle.write(contentsOf: quotaLine(42, timestamp: "2026-10-25T11:00:00Z")); try handle.close()
    usage.scan(); try require(usage.latest?.primaryUsed == 42, "Appended quota is incrementally read")
    try quotaLine(8, timestamp: "2026-10-25T12:00:00Z").write(to: log, options: .atomic)
    usage.scan(); try require(usage.latest?.primaryUsed == 8, "File replacement/truncation resets cursor")
    try require(usage.latest?.metric(now: Date(timeIntervalSince1970: 0)).text == "5h 92%\n周 95%", "Remaining quota labels")

    let database = temp.appendingPathComponent("history.sqlite")
    var db: OpaquePointer?; sqlite3_open(database.path, &db); defer { sqlite3_close(db) }
    let schema = "CREATE TABLE thread_turns(thread_id TEXT,turn_id TEXT,status TEXT); CREATE TABLE thread_items(thread_id TEXT,turn_id TEXT,item_type TEXT,rollout_ordinal INTEGER,item_json TEXT);"
    try require(sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK, "SQLite fixture created")
    try require(CodexStatusReader.read(database: database).text == "Codex\n就绪", "No active turn is ready")
    sqlite3_exec(db, "INSERT INTO thread_turns VALUES('a','b','running');", nil, nil, nil)
    try require(CodexStatusReader.read(database: database).text == "Codex\n忙 1", "Running Codex turn")
    sqlite3_exec(db, "INSERT INTO thread_items VALUES('a','b','agentMessage',1,'{\"phase\":\"final_answer\"}');", nil, nil, nil)
    try require(CodexStatusReader.read(database: database).text == "Codex\n待确认 1", "Waiting takes precedence")
    try require(CodexStatusReader.read(database: temp.appendingPathComponent("absent")).text == "Codex\n?", "Unavailable status is not incorrectly ready")

    var legacy = AppConfiguration.standard
    legacy.restoreVendorOnQuit = true; legacy.connectOnLaunch = false
    legacy.pages[0].keys[11].kind = .vsdMemory; legacy.pages[0].keys[12].kind = .vsdCPU
    let migrated = legacy.applyingNativeDefaults()
    try require(migrated.connectOnLaunch && !migrated.restoreVendorOnQuit, "Old installations adopt automatic native connection without vendor restore")
    try require(migrated.pages[0].keys[11].kind == .appMemory && migrated.pages[0].keys[12].kind == .appCPU, "Third-row vendor monitors become LeanDock monitors")
    try require(migrated.pages.flatMap(\.keys).map(\.id) == legacy.pages.flatMap(\.keys).map(\.id), "Migration keeps note/todo key IDs")
    var customized = migrated; customized.connectOnLaunch = false; customized.pages[0].keys[11].kind = .clock
    try require(customized.applyingNativeDefaults() == customized, "Migration is idempotent and preserves later user choices")
    var legacyJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as! [String: Any]
    legacyJSON.removeValue(forKey: "nativeDefaultsVersion")
    let decodedLegacy = try JSONDecoder().decode(AppConfiguration.self, from: json(legacyJSON))
    try require(decodedLegacy.applyingNativeDefaults() == migrated, "Existing config without migration version loads successfully")
    try require(AppConfiguration.standard.connectOnLaunch && !AppConfiguration.standard.restoreVendorOnQuit && AppConfiguration.standard.pages[0].keys[11].kind == .appMemory, "Fresh defaults use the native app")
    let vendor = "/Applications/VSD Craft.app/Contents/MacOS/VSD Craft"
    let helper = "/Users/test/Library/Application Support/StreamDockLights/toggle_lights_server.py"
    let processes: [VendorProcesses.Entry] = [
        .init(pid: 10, parent: 1, user: 501, executable: vendor),
        .init(pid: 11, parent: 10, user: 501, executable: "/usr/local/bin/node"),
        .init(pid: 12, parent: 11, user: 501, executable: "/usr/bin/helper"),
        .init(pid: 13, parent: 1, user: 501, executable: "/usr/bin/python3", arguments: "python3 \(helper)"),
        .init(pid: 14, parent: 1, user: 501, executable: "/Users/test/Library/Application Support/HotSpot/StreamDock/Plugins/calendar.sdPlugin/plugin"),
        .init(pid: 15, parent: 1, user: 501, executable: "/usr/bin/python3", arguments: "python3 unrelated.py"),
        .init(pid: 16, parent: 1, user: 502, executable: vendor),
        .init(pid: 17, parent: 1, user: 501, executable: "/bin/zsh", arguments: "echo \(helper)"),
        .init(pid: 18, parent: 10, user: 501, executable: "/Applications/LeanDock.app/Contents/MacOS/LeanDock")]
    try require(VendorProcesses.targets(in: processes, user: 501, excluding: 18) == Set([10,11,12,13,14]), "Vendor shutdown includes children and orphan helpers, excludes unrelated and other users' processes")
    try require(VendorProcesses.targets(in: [], user: 501, excluding: 18).isEmpty, "Empty vendor process set is harmless")

    let store = ConfigurationStore(directory: temp.appendingPathComponent("settings"))
    let config = AppConfiguration.standard; try store.save(config)
    try require(try store.loadConfiguration() == config, "Independent configuration roundtrip")
    var invalid = config; invalid.pages[0].keys.removeLast()
    do { try store.save(invalid); throw LeanDockError.message("Invalid configuration was saved") } catch { }
    try require(try store.loadConfiguration() == config, "Invalid save cannot overwrite working configuration")
    var content = UserContent(); content.notes["one"] = [.init(title: "标题", content: "内容")]
    var todo = Todo(); todo.title = "到期"; todo.deadline = Date(timeIntervalSince1970: 100); content.todos["todo"] = todo
    try store.save(content); try require(try store.loadContent() == content, "Notes and todo persist independently")
    let dashboard = config.pages[0], uptimeKey = dashboard.keys[0]
    let moved = try config.relocatingKey(id: uptimeKey.id, inPage: dashboard.id, to: 10)
    try require(moved.pages[0].keys[10] == uptimeKey && moved.pages[0].keys[0].kind == .empty, "Drop on an empty slot moves the whole key")
    try require(Set(moved.pages.flatMap(\.keys).map(\.id)) == Set(config.pages.flatMap(\.keys).map(\.id)) && moved.pages[1] == config.pages[1], "Moving preserves all IDs and other pages")
    let swapped = try config.relocatingKey(id: uptimeKey.id, inPage: dashboard.id, to: 6)
    try require(swapped.pages[0].keys[0] == dashboard.keys[6] && swapped.pages[0].keys[6] == uptimeKey, "Drop on an occupied slot exchanges both complete keys")
    try require(try swapped.relocatingKey(id: uptimeKey.id, inPage: dashboard.id, to: 0) == config, "Moving back restores the exact layout")
    try require(try config.relocatingKey(id: uptimeKey.id, inPage: dashboard.id, to: 0) == config, "Drop at the same position is a no-op")
    for (keyID, pageID, destination) in [(uptimeKey.id, dashboard.id, -1), (uptimeKey.id, dashboard.id, 15),
                                        (uptimeKey.id, "absent-page", 1), ("absent-key", dashboard.id, 1),
                                        (dashboard.keys[10].id, dashboard.id, 1)] {
        var rejected = false
        do { _ = try config.relocatingKey(id: keyID, inPage: pageID, to: destination) } catch { rejected = true }
        try require(rejected, "Reject invalid or stale drag source/destination")
    }
    let notesKey = config.pages[1].keys[0], todoKey = config.pages[1].keys[1]
    var associated = UserContent()
    associated.notes[notesKey.id] = [.init(title: "Keep this note", content: "Moves with its key ID")]
    associated.todos[todoKey.id] = todo
    let exchangedNotes = try config.relocatingKey(id: notesKey.id, inPage: config.pages[1].id, to: 1)
    let dragStore = ConfigurationStore(directory: temp.appendingPathComponent("drag-settings"))
    try dragStore.save(configuration: exchangedNotes, content: associated)
    let restoredLayout = try dragStore.loadConfiguration()!, restoredContent = try dragStore.loadContent()
    try require(restoredLayout == exchangedNotes && restoredContent == associated, "Dragged layout and note/todo data persist atomically")
    try require(restoredContent.notes[restoredLayout.pages[1].keys[1].id] == associated.notes[notesKey.id] && restoredContent.todos[restoredLayout.pages[1].keys[0].id] == todo, "Notes and todo follow their keys after a swap and reload")
    let movedLights = try config.relocatingKey(id: dashboard.keys[14].id, inPage: dashboard.id, to: 10)
    try require(movedLights.pages[0].keys.firstIndex { $0.kind == .lights } == 10, "Light input binding follows the moved light key")
    try require(todo.remaining(at: Date(timeIntervalSince1970: 90)) == "00:00:10", "Countdown uses an absolute deadline")
    try require(todo.remaining(at: Date(timeIntervalSince1970: 101)) == "Time out", "Expired hidden-page todo remains expired")
    let profile = temp.appendingPathComponent("fixture.sdProfile"); try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
    let fixture: [String: Any] = ["DeviceUUID": "M18V25E", "Actions": ["0,2": ["UUID": "com.yololippy.streamdock.togglelights.uptime", "ActionID": "uptime"],
        "4,0": ["UUID": "com.yololippy.streamdock.togglelights.toggle", "ActionID": "lights"],
        "1,2": ["UUID": "vendor.unknown.action", "ActionID": "unknown", "Name": "unknown"]]]
    try json(fixture).write(to: profile.appendingPathComponent("manifest.json"))
    let imported = try VSDImporter.read(profile: profile)
    try require(imported.configuration.pages[0].keys[0].kind == .uptime && imported.configuration.pages[0].keys[14].kind == .lights, "VSD bottom-up coordinates imported correctly")
    try require(imported.warnings.count == 1 && imported.configuration.pages[0].keys[1].kind == .unsupported, "Unsupported actions remain visible")

    let renderer = KeyRenderer(), key = config.pages[0].keys[0], face = KeyFace(kind: .uptime, text: "21时4分", status: "fixed")
    let image = try renderer.render(key: key, face: face)
    _ = try renderer.render(key: key, face: face)
    try require(renderer.encodedFrames == 1, "Unchanged keys skip image encoding")
    let source = CGImageSourceCreateWithData(image as CFData, nil)!
    let raster = CGImageSourceCreateImageAtIndex(source, 0, nil)!
    try require(raster.width == 64 && raster.height == 64, "Native JPEG uses actual 64x64 key resolution")
    renderer.retainOnly([]); try require(renderer.cachedImageCount == 0, "Hidden-page frame caches are released")
    let preview = temp.appendingPathComponent("preview.png"); try KeyRenderer.preview(frames: Array(repeating: image, count: 15), at: preview)
    try require(try Data(contentsOf: preview).prefix(8) == Data([137,80,78,71,13,10,26,10]), "Offline preview is a valid PNG")
}

do { try run(); print("LeanDock: \(checks) hardware-independent checks passed") }
catch { FileHandle.standardError.write(Data("FAIL: \(error.localizedDescription)\n".utf8)); exit(1) }
