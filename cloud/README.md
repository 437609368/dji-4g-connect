# DJI 4G 云端短信中继

这是 iPhone 客户端和云端之间的最小短信 API。云端不直接接触 SIM 或 QDC507；iPhone 负责读取模块 AT 接口，云端负责保存消息和排队发送命令。

## 启动

```bash
export DJI4G_CLOUD_TOKEN='换成一段随机长 token'
python3 cloud/server.py
```

生产环境请放在 HTTPS 反向代理后；如果不希望改动现有反向代理，也可以设置 `DJI4G_CERT` 和 `DJI4G_KEY` 让服务直接提供 HTTPS。将 `DJI4G_BIND=0.0.0.0` 只用于云服务器。数据库默认保存到 `cloud/relay.sqlite3`，可用 `DJI4G_DB` 改位置。

## API

所有 `/api/v1/*` 请求都需要：

```text
Authorization: Bearer <DJI4G_CLOUD_TOKEN>
```

设备上报短信：

```text
POST /api/v1/devices/<device-id>/messages
{"id":"uuid","direction":"incoming","number":"+8613800000000","body":"验证码 1234","date":"2026-09-10T12:00:00Z"}
```

云端排队发送短信：

```text
POST /api/v1/devices/<device-id>/commands
{"type":"send_sms","to":"+8613800000000","body":"测试"}
```

设备轮询并确认命令：

```text
GET  /api/v1/devices/<device-id>/commands
POST /api/v1/devices/<device-id>/commands/ack
{"id":"command-uuid","status":"done"}
```

当前版本只实现短信中继和电话 API 占位，不接受任意 AT 字符串，也没有电话音频接口。iOS 的 CallKit 需要 SIP/WebRTC 语音后端；未接入后端时，电话接口会返回 501，客户端会显示失败而不是假装接通。

电话后端可以把呼叫状态写回中继：

```text
POST /api/v1/devices/<device-id>/calls
{"number":"+8613800000000"}

GET  /api/v1/devices/<device-id>/calls/<call-id>
POST /api/v1/devices/<device-id>/calls/<call-id>/events
{"status":"connected","mediaURL":"wss://voice.example/call-id"}

DELETE /api/v1/devices/<device-id>/calls/<call-id>
```

状态可用 `ringing`、`connected`、`ended`、`failed`。当前中继只保存状态，不承载 RTP/WebRTC 音频；需要另行部署语音后端，并让它调用 events 接口。

发送命令会被保存为 `pending`，由在线设备取走并在真正完成 AT 操作后调用 `commands/ack`。如果设备掉线，已领取但未确认的命令会在约 60 秒后重新可领取。
