# DJI 4G Connect iOS

这是 iPhone/iPad/Mac Catalyst 的第一版客户端：使用系统网络接口识别 USB 以太网，通过云端 API 同步短信，并保留本地 AT 桥接探测作为硬件接入占位。

Mac Catalyst 版本使用系统 CallKit 通话界面；原生 macOS 主程序不能直接链接 CallKit。Catalyst 版本的电话控制走 `CloudCallKit.swift`：填写云端配置时走云端线路，未填写时通过模块 AT 桥接直接拨号。实际语音仍需要模块提供 USB 音频，或已配置的 SIP/WebRTC/PSTN 云端媒体后端。

IG830 已在 iPad Pro 上被识别为 `Baiwangd` 以太网并可以上网，因此 App 不需要安装 USB 驱动，也不修改系统网络配置。电话控制需要模块侧同时提供 TCP/HTTP AT 桥接；App 会真实探测，未发现时不会伪造“已连接”。

## 打开和运行

1. 用 Xcode 打开 `DJI4GConnectIOS.xcodeproj`。
2. 在 Signing & Capabilities 里选择你的 Apple Account/Team。
3. 选择 iPhone/iPad，或选择 `My Mac (Mac Catalyst)`，点击 Run。

模拟器只能验证界面和联网检测；USB 以太网请使用真实设备。

## 云端短信

在 App 的“云端短信”区域填写：

* 云服务器 HTTPS 地址；
* 当前 iPhone 的设备 ID；
* 云服务器访问令牌。

云端服务代码位于仓库根目录的 `cloud/server.py`，启动方式见 `cloud/README.md`。当前 App 已完成短信列表读取和发送命令入队；真正把命令写入 QDC507，仍需要 iOS 获得 USB AT 访问权限并接入硬件传输层。

## 电话直连前提

App 会探测 `192.168.225.1` 等 ECM 网关上的 `/api/status`、`/api/at` 或 AT TCP 端口。公开的 iOS 代码只能作为客户端，不能替模块固件创建这些服务；如果探测失败，需要先给 IG830 配置模块侧桥接程序，或使用外部硬件网关。

## 云端电话

填写云端配置后，电话按钮通过 CallKit 发起云端 VoIP 呼叫，并预留 PushKit 来电唤醒。CallKit 只提供系统通话界面，实际语音需要云端 SIP/WebRTC/PSTN 后端；`cloud/server.py` 当前只返回“语音后端未配置”的明确错误，尚未伪造通话成功。
