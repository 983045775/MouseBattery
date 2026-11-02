// MouseBattery — ATK/VXE 8K NANO dongle 电量菜单栏小程序
// 通讯方式：内嵌 hidapi C 库（与官方 ATK HUB mac 版一致的底层方案）。
//   此前直接用 IOKit 注册 input report 回调收不到回报（该接收器不广播输入报告），
//   官方 mac 客户端走 node-hid(=hidapi)，实测 hidapi 能稳定收到回报。
// 协议来自 ATK HUB (v3-hub.atkgear.com) 的 WebHID 驱动实现，真机验证 95%。
//
// 通道策略：不常驻持有接收器。每次读取都重新「打开 → 握手 → 请求电量 → 立即关闭」，
//   避免与浏览器 ATK HUB 网页抢占通道；失败则显示 --，下个周期重新建立通道。

import AppKit
import Darwin
import IOKit.hid

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
    static let maxAttempts = 3              // 单次刷新内最多重建通道的次数（鼠标休眠时首次请求可能无响应）

    /// 每次读取完成后在主线程回调；参数为电量，nil 表示本次读取失败
    var onResult: ((Int?) -> Void)?
    var verbose = false

    /// 仅在主线程读写
    private(set) var lastBattery: Int?

    private let queue = DispatchQueue(label: "atk.mousebattery.hid")

    private enum OpResult { case ok, timeout, error }
    private enum BatteryResult { case level(Int), timeout, error }
    private enum ReadResult { case report(UInt8, [UInt8]), timeout, error }

    func start() {
        let rc = atk_hid_init()
        if rc != 0 { log("hid_init 失败: \(rc)") }
    }

    /// 强制重新建立通道并请求一次电量（串行队列，不会并发操作设备）
    /// attempts：本次刷新内最多重建通道的次数
    func refresh(attempts: Int = DongleClient.maxAttempts) {
        queue.async { [weak self] in self?.refreshSync(attempts: attempts) }
    }

    // MARK: 刷新逻辑（后台队列）

    private func refreshSync(attempts: Int) {
        var level: Int?
        for attempt in 1...max(1, attempts) {
            level = readOnce()
            if level != nil { break }
            log("第 \(attempt) 次读取失败")
            if attempt < attempts { usleep(1_000_000) }
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lastBattery = level
            self.onResult?(level)
        }
    }

    /// 完整走一遍：枚举 → 打开 → 握手 → 取电量 → 关闭
    private func readOnce() -> Int? {
        guard let head = atk_hid_enumerate(Self.vendorID, Self.productID) else {
            log("未找到 ATK 设备 (VID 0x373B)")
            return nil
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
            defer { atk_hid_close(dev) }   // 用完立即释放通道
            atk_hid_set_nonblocking(dev, 1)
            log("已打开: \(e.path) usage_page=0x\(String(e.usagePage, radix: 16))")

            drainInput(dev)
            guard handshake(on: dev) == .ok else { continue }
            if case .level(let v) = requestBattery(on: dev) { return v }
        }
        log("所有候选接口均未取得电量")
        return nil
    }

    // MARK: 命令收发

    /// 丢弃缓冲中的旧回报，避免把上次残留当成本次回包
    private func drainInput(_ dev: OpaquePointer) {
        var buf = [UInt8](repeating: 0, count: 64)
        for _ in 0..<16 {
            let n = buf.withUnsafeMutableBufferPointer { p in
                atk_hid_read(dev, p.baseAddress, 64)
            }
            if n <= 0 { break }
        }
    }

    private func handshake(on dev: OpaquePointer) -> OpResult {
        var rng = SystemRandomNumberGenerator()
        let payload = (0..<4).map { _ in UInt8.random(in: 0...255, using: &rng) }
        sendFrame(cmd: Self.cmdDownloadData, payload: payload, validLen: 8, on: dev)
        switch readResponse(dev, cmd: Self.cmdDownloadData, ms: 700) {
        case .report: return .ok
        case .timeout: return .timeout
        case .error: return .error
        }
    }

    private func requestBattery(on dev: OpaquePointer) -> BatteryResult {
        sendFrame(cmd: Self.cmdBattery, payload: [], validLen: 0, on: dev)
        switch readResponse(dev, cmd: Self.cmdBattery, ms: 700) {
        case .report(_, let data):
            let level = Int(data[6])   // 17 字节回报：[0]=ID, [1]=cmd, [5]=validLen, [6]=电量
            if level >= 1 && level <= 100 {
                log("battery level: \(level)")
                return .level(level)
            }
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

    /// 等待指定命令的回报，其他命令的回报直接跳过
    private func readResponse(_ dev: OpaquePointer, cmd: UInt8, ms: Int) -> ReadResult {
        var buf = [UInt8](repeating: 0, count: 64)
        let deadline = Date().addingTimeInterval(Double(ms) / 1000.0)
        while Date() < deadline {
            let n = buf.withUnsafeMutableBufferPointer { p in
                atk_hid_read(dev, p.baseAddress, 64)
            }
            if n > 0 {
                let data = Array(buf[0..<min(Int(n), 64)])
                if data.count >= 7, data[0] == Self.reportID, data[1] == cmd {
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

    private func log(_ s: String) {
        if verbose { mbLog(s) }
    }
}

// MARK: - 菜单栏应用

final class AppDelegate: NSObject, NSApplicationDelegate {
    static let pollInterval: TimeInterval = 300   // 读取成功后的自动读取间隔：5 分钟
    static let retryInterval: TimeInterval = 5    // 读取失败（显示 --）后的重试间隔
    static let wakeDelay: TimeInterval = 5        // 唤醒后等接收器恢复

    private var statusItem: NSStatusItem?
    private let client = DongleClient()
    private var pollTimer: Timer?
    private var lastSucceeded = true
    private var wakeWork: DispatchWorkItem?
    private var autoLaunchItem: NSMenuItem?
    private var refreshItem: NSMenuItem?
    private var permissionItem: NSMenuItem?
    private var wakeObserver: NSObjectProtocol?
    private var pending = 0   // 在途刷新数量
    private var baseIcon: NSImage?
    private var spinnerTimer: Timer?
    private var spinnerAngle: CGFloat = 90
    private var lastTrigger = Date.distantPast
    private static let minSpinnerTime: TimeInterval = 0.8

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

        ensureInputMonitoring()
        setupStatusItem()
        client.onResult = { [weak self] level in
            guard let self else { return }
            // 转圈至少显示 0.8 秒，避免读取太快时看不到反馈
            let remain = max(0, Self.minSpinnerTime - Date().timeIntervalSince(self.lastTrigger))
            DispatchQueue.main.asyncAfter(deadline: .now() + remain) { [weak self] in
                guard let self else { return }
                self.pending = max(0, self.pending - 1)
                self.lastSucceeded = level != nil
                self.updateStatus()
                // 成功：5 分钟后再读；失败：每 5 秒重试，直到读到为止
                self.scheduleNext(after: level != nil ? Self.pollInterval : Self.retryInterval)
            }
        }
        client.start()

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.scheduleWakeRefresh()
        }
        refreshNow()
    }

    // MARK: 输入监控权限（macOS 要求 HID 设备访问必须授权，否则 IOHIDDeviceOpen 被 TCC 拒绝）

    private var hasInputMonitoring: Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    private func ensureInputMonitoring() {
        if hasInputMonitoring { return }
        // 首次会弹出系统授权框，并把本 app 加入「输入监控」列表；菜单栏 app 需先激活才能弹出
        NSApp.activate(ignoringOtherApps: true)
        let granted = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        mbLog("输入监控授权请求结果: \(granted)")
    }

    @objc private func openInputMonitoringSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }

    /// 触发一次读取；读取期间不排下一次，结果回来后再按成功/失败决定间隔
    /// - Parameter quick: 失败后的自动重试只尝试一次，避免单次读取耗时过长导致转圈不断
    private func triggerRefresh(quick: Bool = false) {
        pollTimer?.invalidate()
        pollTimer = nil
        pending += 1
        lastTrigger = Date()
        updateStatus()
        client.refresh(attempts: quick ? 1 : DongleClient.maxAttempts)
    }

    private func scheduleNext(after interval: TimeInterval) {
        pollTimer?.invalidate()
        let t = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.triggerRefresh(quick: !self.lastSucceeded)
        }
        RunLoop.main.add(t, forMode: .common)   // 菜单展开时也能触发
        pollTimer = t
    }

    private func scheduleWakeRefresh() {
        wakeWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.triggerRefresh() }
        wakeWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.wakeDelay, execute: w)
    }

    // MARK: UI

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item

        let menu = NSMenu()
        menu.autoenablesItems = false   // 手动控制“刷新中”时的禁用状态
        let titleItem = NSMenuItem(title: "ATK 鼠标电量", action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        menu.addItem(titleItem)
        menu.addItem(.separator())

        let refresh = NSMenuItem(title: "刷新电量", action: #selector(refreshNow), keyEquivalent: "")
        refresh.target = self
        menu.addItem(refresh)
        refreshItem = refresh

        let perm = NSMenuItem(title: "⚠️ 需要「输入监控」权限，点此打开设置", action: #selector(openInputMonitoringSettings), keyEquivalent: "")
        perm.target = self
        perm.isHidden = true
        menu.addItem(perm)
        permissionItem = perm

        let auto = NSMenuItem(title: "开机自启", action: #selector(toggleAutoLaunch), keyEquivalent: "")
        auto.target = self
        menu.addItem(auto)
        autoLaunchItem = auto

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)

        item.menu = menu
        updateStatus()
        updateAutoLaunchState()
    }

    private func updateStatus() {
        refreshItem?.title = pending > 0 ? "刷新中…" : "刷新电量"
        refreshItem?.isEnabled = pending == 0
        permissionItem?.isHidden = hasInputMonitoring

        guard let b = statusItem?.button else { return }
        if let pct = client.lastBattery {
            baseIcon = NSImage(systemSymbolName: "computermouse.fill", accessibilityDescription: "mouse")
            b.title = " \(pct)%"
            b.contentTintColor = pct <= 20 ? .systemOrange : nil
        } else {
            baseIcon = NSImage(systemSymbolName: "computermouse", accessibilityDescription: "mouse")
            b.title = " --"
            b.contentTintColor = .tertiaryLabelColor
        }
        baseIcon?.isTemplate = true

        if pending > 0 {
            startSpinner()
        } else {
            stopSpinner()
        }
        applyIcon()
    }

    // MARK: 刷新中的小转圈（画在鼠标图标右侧、数字左侧）

    private func startSpinner() {
        guard spinnerTimer == nil else { return }
        let t = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.spinnerAngle = (self.spinnerAngle - 30).truncatingRemainder(dividingBy: 360)
            self.applyIcon()
        }
        RunLoop.main.add(t, forMode: .common)
        spinnerTimer = t
    }

    private func stopSpinner() {
        spinnerTimer?.invalidate()
        spinnerTimer = nil
    }

    private func applyIcon() {
        guard let b = statusItem?.button, let base = baseIcon else { return }
        b.image = spinnerTimer == nil ? base : Self.iconWithSpinner(base: base, angle: spinnerAngle)
    }

    private static func iconWithSpinner(base: NSImage, angle: CGFloat) -> NSImage {
        let spin: CGFloat = 11, gap: CGFloat = 3
        let h = max(base.size.height, spin)
        let size = NSSize(width: base.size.width + gap + spin, height: h)
        let img = NSImage(size: size, flipped: false) { _ in
            base.draw(in: NSRect(x: 0, y: (h - base.size.height) / 2,
                                 width: base.size.width, height: base.size.height))
            let center = NSPoint(x: base.size.width + gap + spin / 2, y: h / 2)
            let arc = NSBezierPath()
            arc.appendArc(withCenter: center, radius: spin / 2 - 1,
                          startAngle: angle, endAngle: angle + 270, clockwise: false)
            arc.lineWidth = 1.6
            arc.lineCapStyle = .round
            NSColor.black.setStroke()
            arc.stroke()
            return true
        }
        img.isTemplate = true
        return img
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
                mbLog("写入 LaunchAgent 失败: \(error)")
            }
        }
        updateAutoLaunchState()
    }

    @objc private func refreshNow() {
        triggerRefresh()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

// MARK: - 入口

if CommandLine.arguments.contains("--test") {
    // 命令行测试模式：重建通道读一次电量并打印
    let client = DongleClient()
    client.verbose = true
    client.onResult = { level in
        if let level {
            print("BATTERY: \(level)%")
            exit(0)
        }
        print("FAIL: 读取电量失败")
        exit(1)
    }
    client.start()
    client.refresh()
    let deadline = Date().addingTimeInterval(15)
    while Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    }
    print("FAIL: 15 秒内无响应")
    exit(1)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
