# DJI 4G Connect

这是一个 macOS 原生小工具：使用第一代 DJI/Baiwang QDC507 4G 模块的自有 SIM 卡上网，并通过 AT 通道读取运营商、信号、短信和电话状态。

程序优先使用 `/dev/cu.*` AT 串口；在 ECM 网卡已经被 macOS 接管、但没有串口节点时，会直接通过 macOS IOKit 打开 QDC507 的 AT bulk interface（ECM 通常为 interface 2/3，RNDIS 会尝试 4/5）。因此“系统设置已显示 Baiwang 已连接”不再等于软件只能显示网卡而无法读运营商。

电话页发送的是模块的 `ATD<number>;`/`ATH` 指令，并按 `AT+CLCC` 的真实状态更新呼叫状态。已接通的通话不会因一次短暂的 AT/CLCC 读取失败而被误报为“呼叫失败”。实际语音通话还取决于 SIM、运营商 VoLTE/CSFB 和模块固件；部分 QDC507 固件虽然会枚举 USB 音频设备，但 `AT+QPCMV?` 返回 `ERROR`，这类固件仍不能把通话媒体路由到 MacBook 扬声器和麦克风，电话页会明确显示该状态。

原生 macOS 工具：让大疆一代 4G 模块使用自己的 SIM 卡为 MacBook 提供移动网络。

## 当前能力

- 自动扫描大疆 / Baiwang / EG25 / QDC 常见 USB 串口
- 通过 AT 指令配置 APN，不刷写模块、不做永久修改
- 可选将模块切换到 macOS 兼容的 ECM 模式（会明确提示这是持久配置，并重启模块）
- 读取运营商和信号强度
- 在总览显示本机号码（由 SIM/运营商通过 `AT+CNUM` 提供时；若返回空结果则显示“运营商未提供”）
- 查找 macOS 创建的 USB 网卡并触发 DHCP
- 一键连接、断开和查看诊断日志
- 短信收件箱、UCS2 中文短信发送
- 进入短信页自动读取，并在页面停留时定时更新
- 电话拨号和挂断，并解析 `AT+CLCC`、`+QIND: "ccinfo"`、`^DSCI` 的接通状态
- 读取 IMS / USB 音频语音配置及 QPCMV 媒体路由能力
- 可手动应用 IMS + USB 音频配置并重启模块
- DJI 黑底白色标志 App 图标

## 构建

需要 macOS 13+ 和 Swift 6。当前机器如果没有完整 Xcode，也可以使用 Command Line Tools 构建：

```bash
./build_app.sh
open "dist/DJI 4G Connect.app"
```

连接时请使用支持数据传输的 USB-C 线，先插入 SIM 卡，再打开 App。App 会读取运营商并自动选择常见 APN；如果运营商未识别，会保留模块当前配置。

## 说明

不同批次模块暴露的 USB 网络模式可能不同。默认情况下 App 不会改变永久 USB 配置；如果 macOS 没有出现 USB 网卡，可以勾选“必要时切换到 ECM 模式”，让模块重新枚举。该选项对应 `AT+QCFG="usbnet",1`，会写入模块 NVRAM 并软重启；需要恢复大疆原始模式时请使用 `AT+QCFG="usbnet",0` 等设备专用工具。

如果 macOS 已经显示 `Baiwang` 网卡，App 可以直接接管现有连接，不要求额外串口。只有在需要配置 APN 或切换 ECM 模式时才需要模块的 AT 串口；某些完全处于大疆私有 USB 模式的批次可能需要 libusb/DriverKit 方式打开 USB AT 接口，后续再补充该兼容层。
