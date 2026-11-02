# MouseBattery

ATK / VXE 无线鼠标电量的 macOS 菜单栏小程序：在菜单栏显示一个小鼠标图标 + 电池百分比，仅此而已。

专为 **8K NANO 无线接收器**（VID `0x373B`，PID `0x111B`，如 ATK A9 Pro Max 配套接收器）设计。再也不用打开浏览器去 ATK HUB 网页看电量了。

## 功能

- 菜单栏常驻：`computermouse` 图标 + 电量百分比（如 `95%`），低于 20% 变橙色
- 每 5 分钟自动读取一次；读取失败显示 `--`，下一个 5 分钟再重新建立通道重试
- 睡眠唤醒约 5 秒后读取一次（等接收器恢复）
- 菜单项：刷新电量（⌘R，强制重新建立通道并立即请求电量，同时重置 5 分钟计时）、开机自启（LaunchAgent）、退出
- 不常驻占用接收器：每次读取都「打开 → 握手 → 取电量 → 立即关闭」，避免与浏览器 ATK HUB 抢通道
- `--test` 命令行模式：读一次电量并打印，方便调试

## 原理

ATK HUB 网页驱动（v3-hub.atkgear.com）通过 WebHID 与接收器通信，协议逆向如下：

- 16 字节 COMPX 帧：`frame[0]` 命令（`1` = DownLoadData 握手，`4` = GetBatteryLevel），`frame[4]` 有效长度，`frame[5..14]` 载荷，`frame[15]` 校验和 = `(85 - ((8 + Σframe[0..14]) & 0xFF)) & 0xFF`
- 以 HID feature report（报告 ID `8`）发送（17 字节 = 报告 ID + 帧）
- 回报是异步 input report（17 字节）：`[8, cmd, 0, 0, 0, validLen, 电量, 充电标志, 电压低字节, 电压高字节, ...]`

一个关键坑：该接收器的 vendor 接口（usage page `0xFF05`）**不广播**输入报告——直接用 IOKit 注册 `IOHIDDeviceRegisterInputReportCallback` 无论怎么试都收不到回报，而 hidapi（官方 ATK HUB mac 版底层用的 node-hid 就是它）能稳定收到。所以本项目把 [hidapi](https://github.com/libusb/hidapi)（mac 后端）直接内嵌进 app，通过一个 60 行的 C 桥接层给 Swift 调用。

## 构建

需要 macOS + Xcode 命令行工具（`cc` / `swiftc`）：

```bash
./build.sh
```

产物：`MouseBattery.app`（已 ad-hoc 签名），拖到「应用程序」即可。

## 使用

- 双击 `MouseBattery.app` 启动，菜单栏出现图标 + 电量
- **首次必须授权「输入监控」**：系统设置 → 隐私与安全性 → 输入监控 → 点 ＋ 添加 `/Applications/MouseBattery.app` 并打开开关，然后重启 app。未授权时 macOS 会拒绝打开 HID 设备（日志中为 `TCC deny IOHIDDeviceOpen`），电量一直显示 `--`；此时菜单里会出现「需要『输入监控』权限」的提示项，点击可直达设置页
- 菜单 → 刷新电量（⌘R）：强制重新建立通道并立即请求，同时重置 5 分钟计时
- 菜单 → 开机自启：写入 `~/Library/LaunchAgents/com.atk.mousebattery.plist`（指向当前 .app 内的可执行文件，建议先放到「应用程序」再勾选）
- 调试：`./MouseBattery --test`，成功则打印 `BATTERY: N%`（命令行下借用终端的权限，能读到不代表 .app 已获授权）

## 已知限制

- 本地 ad-hoc 签名，每次重新编译后 cdhash 会变，输入监控授权可能失效，需要在设置里删掉旧条目重新添加

- 如果浏览器里的 ATK HUB 网页或官方 ATK HUB 客户端正占用接收器，本次读取可能失败显示 `--`；点「刷新电量」重试，或等下个 5 分钟自动重试
- 键盘接口被 Karabiner 独占不影响本程序（走的是 vendor 接口）
- 充电状态不回显（回包标志字节含义不可靠，只显示电量百分比）

## 目录结构

```
MouseBattery.swift   菜单栏 app（Swift，AppKit + hidapi 桥接）
atk_bridge.h/.c      hidapi 的 Swift 桥接（隐藏 wchar_t 字段）
hidapi/              内嵌的 hidapi 源码（mac 后端，含独占打开失败降级补丁）
build.sh             一键构建 + 打包 .app
```

## 协议与参考

- hidapi：[libusb/hidapi](https://github.com/libusb/hidapi)，BSD / GPLv3 / 原版三授权，本项目按 BSD 使用（见 `hidapi/LICENSE-bsd.txt`）
- 协议参考了 [atktool](https://github.com/naseaoi/atktool)（Rust）与 [atk-battery-tray](https://github.com/Lnyun-coder/atk-battery-tray)（Windows）的通信代码
