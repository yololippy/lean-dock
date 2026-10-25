import Foundation

public struct DeviceStatus: Codable {
    public var connected = false
    public var asleep = false
    public var message = "预览模式 · 尚未连接设备"
    public var sentFrames = 0
    public var inputEvents = 0
    public var lastPosition: Int?
    public init() {}
}

/// At most one latest complete page is pending, regardless of producer speed.
public struct LatestFrameBuffer {
    private var value: [Data]?
    public init() {}
    public var count: Int { value?.count ?? 0 }
    public mutating func replace(_ frames: [Data]) { guard frames.count == 15 else { return }; value = frames }
    public mutating func take() -> [Data]? { defer { value = nil }; return value }
}

public final class DeckEngine {
    private let queue = DispatchQueue(label: "com.yololippy.LeanDock.device", qos: .userInitiated)
    private let mailboxLock = NSLock()
    private var mailbox = LatestFrameBuffer()
    private var scheduled = false
    private var device: M18Device?
    private var desiredFrames: [Data] = []
    private var sentFrames: [Int: Data] = [:]
    private var timer: DispatchSourceTimer?
    private var configuration = DeviceConfiguration()
    private var wantsConnection = false
    private var desiredSleep = false
    private var nextAttempt: TimeInterval = 0
    private var retryDelay: TimeInterval = 1
    private var generation = UUID()
    private var lighting = LightingController()
    private var input = InputGate()
    private var lightPosition: Int? = 14
    private var status = DeviceStatus()
    private var activity: NSObjectProtocol?
    public var onStatus: ((DeviceStatus) -> Void)?
    public var onActivate: ((Int) -> Void)?
    public init() {}

    public func connect(_ configuration: DeviceConfiguration) {
        queue.async { [self] in
            self.configuration = configuration; wantsConnection = true; nextAttempt = 0; retryDelay = 1
            if activity == nil {
                activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "保持 M18 原生连接")
            }
            if timer == nil {
                let timer = DispatchSource.makeTimerSource(queue: queue)
                timer.schedule(deadline: .now(), repeating: 2, leeway: .milliseconds(100))
                timer.setEventHandler { [weak self] in self?.heartbeat() }; self.timer = timer; timer.resume()
            }
            tryConnect()
        }
    }
    public func disconnect(completion: (() -> Void)? = nil) {
        queue.async { [self] in
            wantsConnection = false; timer?.cancel(); timer = nil
            generation = UUID()
            device?.close(); device = nil; sentFrames.removeAll(); input = InputGate()
            if let activity { ProcessInfo.processInfo.endActivity(activity); self.activity = nil }
            status.connected = false; status.message = "预览模式 · 已断开设备"; publish()
            completion?()
        }
    }
    public func setLightPosition(_ position: Int?) { queue.async { self.lightPosition = position } }
    public func setBrightness(screen: Int, ring: Int) {
        queue.async { [self] in
            configuration.screenBrightness = max(1, min(100, screen)); configuration.ringBrightness = max(0, min(100, ring))
            guard let device, !desiredSleep else { return }
            do { try device.write(M18Protocol.brightness(configuration.screenBrightness)); try device.write(M18Protocol.ring(configuration.ringBrightness)) }
            catch { failed(error) }
        }
    }
    public func toggleLights() { queue.async { self.applyLights(on: self.desiredSleep) } }
    public func wake() { queue.async { self.applyLights(on: true) } }

    public func updateFrames(_ frames: [Data]) {
        mailboxLock.lock(); mailbox.replace(frames)
        let needsSchedule = !scheduled; scheduled = true; mailboxLock.unlock()
        if needsSchedule { queue.async { self.pump() } }
    }
    private func pump() {
        mailboxLock.lock(); let latest = mailbox.take(); mailboxLock.unlock()
        if let latest {
            desiredFrames = latest
            if device != nil && !desiredSleep {
                do { try flush() } catch { failed(error) }
            }
        }
        mailboxLock.lock()
        let again = mailbox.count > 0; scheduled = again; mailboxLock.unlock()
        if again { queue.async { self.pump() } }
    }
    private func tryConnect() {
        guard wantsConnection, device == nil, ProcessInfo.processInfo.systemUptime >= nextAttempt else { return }
        let candidate = M18Device()
        let connectionGeneration = UUID(); generation = connectionGeneration
        candidate.onInput = { [weak self] event in self?.queue.async {
            guard let self, self.generation == connectionGeneration else { return }; self.handle(event)
        } }
        candidate.onRemoval = { [weak self] in self?.queue.async {
            guard let self, self.generation == connectionGeneration else { return }
            self.failed(LeanDockError.message("M18 已断开，等待重新连接。"))
        } }
        do {
            try candidate.open(configuration: configuration)
            try candidate.write(M18Protocol.mode)
            Thread.sleep(forTimeInterval: 0.05)
            try candidate.write(M18Protocol.verb("DIS"))
            try candidate.write(M18Protocol.brightness(configuration.screenBrightness))
            try candidate.write(M18Protocol.ring(configuration.ringBrightness))
            try candidate.write(M18Protocol.clear)
            device = candidate; sentFrames.removeAll(); input = InputGate(); retryDelay = 1
            try flush()
            if desiredSleep { try lighting.apply(on: false, config: configuration, write: candidate.write) }
            status.connected = true; status.asleep = desiredSleep
            status.message = desiredSleep ? "已连接 · 屏幕和灯环休眠" : "M18 已连接 · 原生控制"; publish()
        } catch { candidate.close(); failed(error) }
    }
    private func heartbeat() {
        guard wantsConnection else { return }
        guard let device else { tryConnect(); return }
        do { try device.write(M18Protocol.verb("CONNECT")) }
        catch { failed(error) }
    }
    private func flush() throws {
        guard let device else { return }
        for (position, image) in desiredFrames.enumerated() where sentFrames[position] != image {
            try device.image(position: position, jpeg: image); sentFrames[position] = image; status.sentFrames += 1
        }
        publish()
    }
    private func applyLights(on: Bool) {
        guard let device else { status.message = "请先连接 M18，再控制灯光。"; publish(); return }
        do {
            try lighting.apply(on: on, config: configuration, write: device.write)
            desiredSleep = !on; status.asleep = !on
            if on { sentFrames.removeAll(); try flush() }
            status.message = on ? "M18 已连接 · 灯光开启" : "屏幕和灯环休眠 · 再按同一 LCD 键恢复"; publish()
        } catch { failed(error) }
    }
    private func handle(_ event: ButtonEvent) {
        status.inputEvents += 1; status.lastPosition = event.position
        switch input.accept(event, asleep: desiredSleep, lightPosition: lightPosition, now: ProcessInfo.processInfo.systemUptime) {
        case .none: break
        case .wake: applyLights(on: true)
        case .activate(let position): onActivate?(position)
        }
        publish()
    }
    private func failed(_ error: Error) {
        generation = UUID()
        device?.close(); device = nil; sentFrames.removeAll(); status.connected = false
        status.message = error.localizedDescription; publish()
        nextAttempt = ProcessInfo.processInfo.systemUptime + retryDelay; retryDelay = min(10, retryDelay * 2)
    }
    private func publish() { onStatus?(status) }
}

public final class SamplingLoop {
    private let queue = DispatchQueue(label: "com.yololippy.LeanDock.sampling", qos: .utility)
    private var configuration: AppConfiguration
    private var content: UserContent
    private var page: Int = 0
    private let collector: MetricCollector
    private let renderer = KeyRenderer()
    private var timer: DispatchSourceTimer?
    public var onUpdate: ((MetricSnapshot, [Data], String, [KeyConfiguration]) -> Void)?
    public var onError: ((String) -> Void)?
    public init(configuration: AppConfiguration, content: UserContent, cacheDirectory: URL) {
        self.configuration = configuration; self.content = content; collector = MetricCollector(cacheDirectory: cacheDirectory)
    }
    public func start() {
        queue.async { [self] in
            guard timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: queue); timer.schedule(deadline: .now(), repeating: 1, leeway: .milliseconds(100))
            timer.setEventHandler { [weak self] in self?.tick() }; self.timer = timer; timer.resume()
        }
    }
    public func update(configuration: AppConfiguration, content: UserContent, page: Int) {
        queue.async { [self] in
            self.configuration = configuration; self.content = content; self.page = min(max(0, page), configuration.pages.count - 1); tick()
        }
    }
    public func stop() { queue.sync { timer?.cancel(); timer = nil } }
    private func tick() {
        autoreleasepool {
            let now = Date(), snapshot = collector.collect(now: now)
            let keys = configuration.pages[page].keys
            renderer.retainOnly(Set(keys.map(\.id)))
            do {
                let frames = try keys.map { try renderer.render(key: $0, face: KeyRenderer.face(for: $0, snapshot: snapshot, content: content, now: now)) }
                onUpdate?(snapshot, frames, configuration.pages[page].id, keys)
            } catch { onError?(error.localizedDescription) }
        }
    }
}
