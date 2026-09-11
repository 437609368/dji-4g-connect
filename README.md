# DJI 4G Connect

这是一个 macOS 原生小工具：使用第一代 DJI/Baiwang QDC507 4G 模块的自有 SIM 卡上网，并通过 AT 通道读取运营商、信号、短信和电话状态。

程序优先使用 `/dev/cu.*` AT 串口；在 ECM 网卡已经被 macOS 接管、但没有串口节点时，会直接通过 macOS IOKit 打开 QDC507 的 AT bulk interface（ECM 通常为 interface 2/3，RNDIS 会尝试 4/5）。因此“系统设置已显示 Baiwang 已连接”不再等于软件只能显示网卡而无法读运营商。

电话功能通过本地 DJOneHub v1.1.1 后端管理 QDC507 的 AT、ADB、D4/UAC 语音路由，只在真实语音 `CLCC` 进入 active 后启动 Mac 麦克风与扬声器桥接。第一次启用会备份模块配置、持久授权 ADB、开启 ADB/UAC/IMS/VoLTE 并重启模块；语音运行时从固定 MaVo 提交下载并校验 SHA-256，只部署到模块临时目录。

原生 macOS 工具：让大疆一代 4G 模块使用自己的 SIM 卡为 MacBook 提供移动网络。

## Mac Catalyst 系统通话界面

原生 macOS SDK 不提供 CallKit 的 `CXProvider`。仓库里的 `iOSApp` 工程已开启 Mac Catalyst，Mac 端电话页会使用系统 CallKit 界面；未填写云端配置时，拨号/接听/挂断通过 AT 桥接发送到模块，填写云端配置时走云端线路。

用 Xcode 打开 [iOSApp/DJI4GConnectIOS.xcodeproj](iOSApp/DJI4GConnectIOS.xcodeproj)，运行目标选择 `My Mac (Mac Catalyst)`。也可以直接使用已构建的 [DJI4GConnectIOS.app](iOSApp/build-catalyst/Build/Products/Debug-maccatalyst/DJI4GConnectIOS.app)。

CallKit 只提供系统通话界面；模块的 USB 音频或云端 SIP/WebRTC/PSTN 媒体通道仍需可用，否则只能看到通话状态，听不到双方声音。

## 云端短信中继

云端短信 API 位于 [cloud/server.py](cloud/server.py)，用于保存 iPhone 上报的短信并排队发送命令。部署说明见 [cloud/README.md](cloud/README.md)。云端不直接连接 QDC507；短信的最终 AT 读写仍由 iPhone 硬件传输层完成。

## 当前能力

- 自动扫描大疆 / Baiwang / EG25 / QDC 常见 USB 串口
- 通过 AT 指令配置 APN；通话模式会在用户确认后持久授权 ADB 并修改 USB 功能位
- 可选将模块切换到 macOS 兼容的 ECM 模式（会明确提示这是持久配置，并重启模块）
- 读取运营商和信号强度
- 在总览显示本机号码（由 SIM/运营商通过 `AT+CNUM` 提供时；若返回空结果则显示“运营商未提供”）
- 查找 macOS 创建的 USB 网卡并触发 DHCP
- 通过 USB 设备存在性判断模块是否真正插入，避免拔出后残留网卡仍显示已连接
- 按“识别模块 → 打开 AT/USB AT → 启用 4G 网络”的流程自动工作
- 关闭 4G 时只停用数据网络，保留模块和 AT 控制状态；重新插拔会自动清理状态
- 一键启用、关闭网络和查看诊断日志
- 短信收件箱、UCS2 中文短信发送
- 模块打开 AT 接口后自动轮询短信，进入短信页可立即刷新
- 电话拨号、来电、接听和挂断，数据会话 `CLCC mode=1` 不会被误判为电话
- 部署 QDC507 3.18.44 语音运行时，并桥接 Mac 麦克风与扬声器
- 可手动应用 IMS + USB 音频配置并重启模块
- DJI 黑底白色标志 App 图标

## 构建

需要 macOS 13+ 和 Swift 6。当前机器如果没有完整 Xcode，也可以使用 Command Line Tools 构建：

当前 Apple Silicon 版：[DJI-4G-Connect-v0.1.6-arm64.zip](DJI-4G-Connect-v0.1.6-arm64.zip)

```bash
./build_app.sh
open "dist/DJI 4G Connect.app"
```

连接时请使用支持数据传输的 USB-C 线，先插入 SIM 卡，再打开 App。App 会先识别 DJI/Baiwang 设备并自动打开 AT 接口，再按需要启用 USB 4G 网络；运营商、SIM、注册状态和 IP 会分别显示，不会把“系统里有 Baiwang 网卡”误判成“网络已经可用”。

## 说明

内置的 `djonehubd` 来自 [DJOneHubNative](https://github.com/cr-zhichen/DJOneHubNative) v1.1.1，遵循 PolyForm Noncommercial 1.0.0，仅限非商业用途。完整许可证和第三方声明会打包到 `Contents/Resources/licenses/DJOneHub/`。

不同批次模块暴露的 USB 网络模式可能不同。默认情况下 App 不会改变永久 USB 配置；只有启用兼容模式时才会写入 `AT+QCFG="usbnet",1` 并让模块重新枚举。普通的关闭/重新启用 4G 不会执行 `CFUN` 重启，避免 Baiwang 网卡重新出现后 DHCP 尚未完成。

如果 macOS 已经显示 `Baiwang` 网卡，App 可以直接接管现有连接，不要求额外串口。只有在需要配置 APN 或切换 ECM 模式时才需要模块的 AT 串口；某些完全处于大疆私有 USB 模式的批次可能需要 libusb/DriverKit 方式打开 USB AT 接口，后续再补充该兼容层。
