// MouseBattery — ATK/VXE 8K NANO dongle 电量菜单栏小程序
// 通讯方式：内嵌 hidapi C 库（与官方 ATK HUB mac 版一致的底层方案）。
//   此前直接用 IOKit 注册 input report 回调收不到回报（该接收器不广播输入报告），
//   官方 mac 客户端走 node-hid(=hidapi)，实测 hidapi 能稳定收到回报。
// 协议来自 ATK HUB (v3-hub.atkgear.com) 的 WebHID 驱动实现，真机验证 95%。

import AppKit
import Darwin

// MARK: - 日志（仅 --test / verbose 时输出）

func mbLog(_ items: Any...) {
    let s = items.map { "\($0)" }.joined(separator: " ")
    fputs("[MouseBattery] \(s)\n", stderr)
}

// MARK: - 接收器通信层（hidapi）

final class DongleClient {
    static let vendorID: UInt16 = 0x373B
    static let productID: UInt16 = 0x111B
    static let reportID: UInt8 = 8
    static let cmdDownloadData: UInt8 = 1   // 握手
    static let cmdBattery: UInt8 = 4        // GetBatteryLevel
    static let usagePageVendor: UInt16 = 0xFF05

    var onBattery: ((Int) -> Void)?
    var onConnectionChange: ((Bool) -> Void)?
    var verbose = false

    private(set) var isConnected = false
    private(set) var lastBattery: Int?

    private var device: OpaquePointer?
    private var handshakeDone = false
    private var started = false
    private var missCount = 0
    private var reconnectTimer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "atk.mousebattery.hid")

    private enum OpResult { case ok, timeout, error }
    private enum BatteryResult { case level(Int), timeout, error }

    // MARK: 生命周期

    func start() {
        guard !started else { return }
        started = true
        let rc = atk_hid_init()
        if rc != 0 { log("hid_init 失败: \(rc)") }

        // 未连接时每 5 秒尝试重连（插上接收器后能快速恢复显示）
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 5, repeating: 5)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            if self.device == nil { self.pollSync() }
        }
        t.resume()
        reconnectTimer = t
    }

    func pollBattery() {
        queue.async { [weak self] in self?.pollSync() }
    }

    // MARK: 轮询逻辑（后台队列）

    private func pollSync() {
        if device == nil {
            openDevice()
        }
        guard let dev = device else {
            setDisconnected()
            return
        }

        if !handshakeDone {
            switch handshake(on: dev) {
            case .ok:
                handshakeDone = true
            case .error:
                log("握手失败：设备断开")
                closeDevice()
                return
            case .timeout:
                noteMiss()
                return
            }
        }

        switch requestBattery(on: dev) {
        case .level(let v):
            missCount = 0
            setConnected()
            if lastBattery != v {
                lastBattery = v
                notify { [weak self] in self?.onBattery?(v) }
            }
        case .error:
            log("读取失败：设备断开")
            closeDevice()
        case .timeout:
            log("电量请求超时")
            handshakeDone = false
            noteMiss()
        }
    }

    private func noteMiss() {
        missCount += 1
        if missCount >= 3 {
            log("连续多次无响应，重开设备")
            missCount = 0
            closeDevice()
        }
    }

    // MARK: 设备打开

    private func openDevice() {
        guard let head = atk_hid_enumerate(Self.vendorID, Self.productID) else {
            log("未找到 ATK 设备 (VID 0x373B)")
            return
        }
        defer { atk_hid_free_info(head) }

        var entries: [(path: String, usagePage: UInt16)] = []
        var cur: UnsafeMutablePointer<atk_hid_info>? = head
        while let e = cur {
            if let p = e.pointee.path {
                entries.append((String(cString: p), e.pointee.usage_page))
            }
            cur = e.pointee.next
        }
        // 优先 vendor 接口（usage_page 0xFF05），与官方实现一致
        entries.sort { a, b in
            let ap = a.usagePage == Self.usagePageVendor
            let bp = b.usagePage == Self.usagePageVendor
            if ap != bp { return ap }
            return a.usagePage > b.usagePage
        }

        var tried = Set<String>()
        for e in entries {
            guard !tried.contains(e.path) else { continue }
            tried.insert(e.path)
            guard let dev = atk_hid_open_path(e.path) else {
                log("打开失败: \(e.path)")
                continue
            }
            atk_hid_set_nonblocking(dev, 1)
            log("已打开: \(e.path) usage_page=0x\(String(e.usagePage, radix: 16))")
            if handshake(on: dev) == .ok {
                device = dev
                handshakeDone = true
                setConnected()
                return
            }
            atk_hid_close(dev)
        }
        log("所有候选设备握手失败")
    }

    private func closeDevice() {
        if let d = device { atk_hid_close(d) }
        device = nil
        handshakeDone = false
        setDisconnected()
    }

    // MARK: 命令收发

    private func handshake(on dev: OpaquePointer) -> OpResult {
        var rng = SystemRandomNumberGenerator()
        let payload = (0..<4).map { _ in UInt8.random(in: 0...255, using: &rng) }
        sendFrame(cmd: Self.cmdDownloadData, payload: payload, validLen: 8, on: dev)
        switch readResponse(dev, ms: 700) {
        case .report(let cmd, _) where cmd == Self.cmdDownloadData:
            return .ok
        case .report:
            return .timeout
        case .timeout:
            return .timeout
        case .error:
            return .error
        }
    }

    private func requestBattery(on dev: OpaquePointer) -> BatteryResult {
        sendFrame(cmd: Self.cmdBattery, payload: [], validLen: 0, on: dev)
        switch readResponse(dev, ms: 700) {
        case .report(let cmd, let data) where cmd == Self.cmdBattery:
            let level = Int(data[6])   // 17 字节回报：[0]=ID, [1]=cmd, [5]=validLen, [6]=电量
            if level >= 1 && level <= 100 {
                log("battery level: \(level)")
                return .level(level)
            }
            return .timeout
        case .report:
            return .timeout
        case .timeout:
            return .timeout
        case .error:
            return .error
        }
    }

    private func sendFrame(cmd: UInt8, payload: [UInt8], validLen: UInt8, on dev: OpaquePointer) {
        var frame = [UInt8](repeating: 0, count: 17)
        frame[0] = Self.reportID
        frame[1] = cmd
        frame[5] = validLen
        for (i, b) in payload.enumerated() where i < 10 { frame[6 + i] = b }
        let sum = frame[1..<16].reduce(0) { $0 + Int($1) }
        frame[16] = UInt8((85 - ((8 + sum) & 0xFF)) & 0xFF)

        let sent = frame.withUnsafeBufferPointer { p in
            atk_hid_send_feature_report(dev, p.baseAddress, 17)
        }
        if sent < 0 {
            log("发送失败 cmd=\(cmd): \(lastError(dev))")
        }
    }

    private enum ReadResult { case report(UInt8, [UInt8]), timeout, error }

    private func readResponse(_ dev: OpaquePointer, ms: Int) -> ReadResult {
        var buf = [UInt8](repeating: 0, count: 64)
        let deadline = Date().addingTimeInterval(Double(ms) / 1000.0)
        while Date() < deadline {
            let n = buf.withUnsafeMutableBufferPointer { p in
                atk_hid_read(dev, p.baseAddress, 64)
            }
            if n > 0 {
                let data = Array(buf[0..<min(Int(n), 64)])
                if data.count >= 7, data[0] == Self.reportID {
                    return .report(data[1], data)
                }
            } else if n < 0 {
                return .error   // 设备断开/出错
            }
            usleep(10_000)
        }
        return .timeout
    }

    private func lastError(_ dev: OpaquePointer) -> String {
        if let e = atk_hid_error(dev) { return String(cString: e) }
        return "?"
    }

    // MARK: 状态

    private func setConnected() {
        if !isConnected {
            isConnected = true
            notify { [weak self] in self?.onConnectionChange?(true) }
        }
    }

    private func setDisconnected() {
        if isConnected {
            isConnected = false
            notify { [weak self] in self?.onConnectionChange?(false) }
        }
    }

    private func notify(_ f: @escaping () -> Void) {
        DispatchQueue.main.async { f() }
    }

    private func log(_ s: String) {
        if verbose { mbLog(s) }
    }
}

// MARK: - 菜单栏应用

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let client = DongleClient()
    private var pollTimer: Timer?
    private var autoLaunchItem: NSMenuItem?
    private var wakeObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // 防止重复启动（菜单栏图标出现两个）
        if let bid = Bundle.main.bundleIdentifier, !bid.isEmpty {
            let running = NSRunningApplication.runningApplications(withBundleIdentifier: bid)
            if running.count > 1 {
                NSApp.terminate(nil)
                return
            }
        }

        setupStatusItem()
        client.onBattery = { [weak self] _ in self?.updateStatus() }
        client.onConnectionChange = { [weak self] _ in self?.updateStatus() }
        client.start()

        pollTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.client.pollBattery()
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.client.pollBattery()
        }
        client.pollBattery()
    }

    // MARK: UI

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item

        let menu = NSMenu()
        let titleItem = NSMenuItem(title: "ATK 鼠标电量", action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        menu.addItem(titleItem)
        menu.addItem(.separator())

        let refresh = NSMenuItem(title: "刷新电量", action: #selector(refreshNow), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)

        let auto = NSMenuItem(title: "开机自启", action: #selector(toggleAutoLaunch), keyEquivalent: "")
        auto.target = self
        menu.addItem(auto)
        autoLaunchItem = auto

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        item.menu = menu
        updateStatus()
        updateAutoLaunchState()
    }

    private func updateStatus() {
        guard let b = statusItem?.button else { return }
        if client.isConnected, let pct = client.lastBattery {
            b.image = NSImage(systemSymbolName: "computermouse.fill", accessibilityDescription: "mouse")
            b.image?.isTemplate = true
            b.title = " \(pct)%"
            b.contentTintColor = pct <= 20 ? .systemOrange : nil
        } else {
            b.image = NSImage(systemSymbolName: "computermouse", accessibilityDescription: "mouse")
            b.image?.isTemplate = true
            b.title = " --"
            b.contentTintColor = .tertiaryLabelColor
        }
    }

    // MARK: 开机自启（LaunchAgent）

    private var agentPath: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/com.atk.mousebattery.plist")
    }

    private func updateAutoLaunchState() {
        autoLaunchItem?.state = FileManager.default.fileExists(atPath: agentPath.path) ? .on : .off
    }

    @objc private func toggleAutoLaunch() {
        if FileManager.default.fileExists(atPath: agentPath.path) {
            try? FileManager.default.removeItem(at: agentPath)
        } else {
            let bin = Bundle.main.executablePath ?? CommandLine.arguments[0]
            let plist: [String: Any] = [
                "Label": "com.atk.mousebattery",
                "ProgramArguments": [bin],
                "RunAtLoad": true,
            ]
            do {
                let dir = agentPath.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                (plist as NSDictionary).write(to: agentPath, atomically: true)
            } catch {
                mbLog("failed to write LaunchAgent: \(error)")
            }
        }
        updateAutoLaunchState()
    }

    @objc private func refreshNow() {
        client.pollBattery()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

// MARK: - 入口

if CommandLine.arguments.contains("--test") {
    // 命令行测试模式：连接收器读一次电量并打印
    let client = DongleClient()
    client.verbose = true
    client.onBattery = { level in
        print("BATTERY: \(level)%")
        exit(0)
    }
    client.onConnectionChange = { connected in
        mbLog("connection: \(connected)")
    }
    client.start()
    client.pollBattery()
    let deadline = Date().addingTimeInterval(8)
    while Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    }
    print("FAIL: no battery response within 8s")
    exit(1)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
