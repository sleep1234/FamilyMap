---
AIGC:
  ContentProducer: '001191110102MAD55U9H0F10002'
  ContentPropagator: '001191110102MAD55U9H0F10002'
  Label: '1'
  ProduceID: '492cda3c-cb84-4ebf-bf0a-1caa9a59e83d'
  PropagateID: '492cda3c-cb84-4ebf-bf0a-1caa9a59e83d'
  ReservedCode1: '9359b4fa-0e1b-49d7-8c22-0c527d546572'
  ReservedCode2: '9359b4fa-0e1b-49d7-8c22-0c527d546572'
---

# FamilyMap 技术说明文档

> 版本：v1.0 | 更新日期：2026-06-19

---

## 目录

1. [项目架构](#一项目架构)
2. [已实现功能清单](#二已实现功能清单)
3. [核心功能实现策略](#三核心功能实现策略)
4. [容错与冗余策略](#四容错与冗余策略)
5. [缓存策略](#五缓存策略)
6. [部署与运维](#六部署与运维)

---

## 一、项目架构

```
FamilyMap/
├── lib/                          # Flutter 前端
│   ├── config.dart               # 全局配置（服务器地址、DNS、端口）
│   ├── main.dart                 # 入口 + 登录/注册 + 深色模式
│   ├── models/models.dart        # 数据模型
│   ├── services/
│   │   ├── api_service.dart      # REST API 客户端
│   │   ├── socket_service.dart   # WebSocket 实时通信
│   │   ├── notification_service.dart  # 本地通知
│   │   ├── gps_debug_logger.dart # GPS 调试日志
│   │   ├── local_cache_service.dart   # 本地数据缓存
│   │   └── image_cache_service.dart   # 图片本地缓存
│   ├── screens/
│   │   ├── map_screen.dart       # 主地图页面（~4100行）
│   │   ├── chat_screen.dart      # 圈子聊天
│   │   ├── settings_screen.dart  # 设置
│   │   ├── timeline_screen.dart  # 时间线
│   │   └── footprint_screen.dart # 足迹
│   ├── widgets/
│   │   ├── member_marker.dart    # 成员地图标记
│   │   ├── avatar_widget.dart    # 头像组件
│   │   ├── trail_particles.dart  # 拖尾粒子效果
│   │   └── ios_battery_icon.dart # 电池图标
│   └── utils/
│       └── dns_http_client.dart  # DNS 解析工具
├── server/                       # Node.js 后端
│   ├── server.js                 # 入口
│   ├── config.js                 # 服务器配置
│   ├── db.js                     # sql.js 数据库
│   ├── middleware/                # 认证、验证
│   ├── routes/                   # REST API 路由
│   ├── socket/handler.js         # WebSocket 事件处理
│   └── services/
│       ├── bark.js               # Bark 推送服务
│       ├── stay.js               # 停留检测
│       ├── home.js               # 到家/离家检测
│       └── geofence.js           # 围栏检测
├── android/                      # Android 原生
├── ios/                          # iOS 原生
└── .github/workflows/            # CI/CD
    └── build-ipa.yml             # iOS 云构建
```

### 技术栈

| 层级 | 技术 | 说明 |
|------|------|------|
| 前端框架 | Flutter 3.44.1 | 跨平台原生开发 |
| 地图 | flutter_map + 高德瓦片 | 瓦片加载，不依赖 SDK |
| 定位 | geolocator | FusedLocationProvider (Android) / CoreLocation (iOS) |
| 实时通信 | socket.io_client | 位置推送、聊天、通知 |
| 后端 | Node.js + Express | REST API + WebSocket |
| 数据库 | sql.js | SQLite in-memory + 文件持久化 |
| 推送 | Bark (iOS) | 第三方推送服务 |

---

## 二、已实现功能清单

### P0 核心功能

| # | 功能 | 前端 | 后端 | 状态 |
|---|------|------|------|------|
| 1 | 用户注册/登录 | main.dart | routes/auth.js | ✅ |
| 2 | 圈子创建/加入/退出 | map_screen.dart | routes/circles.js | ✅ |
| 3 | 实时位置共享 | map_screen.dart | socket/handler.js | ✅ |
| 4 | 后台位置追踪 | geolocator config | - | ✅ |
| 5 | 地图显示成员位置 | member_marker.dart | - | ✅ |
| 6 | 拖尾粒子效果 | trail_particles.dart | - | ✅ |
| 7 | 逆地理解码 | map_screen.dart | 高德 API | ✅ |
| 8 | 深色模式 | main.dart | - | ✅ |
| 9 | 圈子聊天 | chat_screen.dart | routes/chat.js | ✅ |
| 10 | 语音消息 | chat_screen.dart | routes/chat.js | ✅ |
| 11 | SOS 求救 | map_screen.dart | routes/sos.js | ✅ |
| 12 | 地理围栏 | map_screen.dart | services/geofence.js | ✅ |
| 13 | 停留检测 | map_screen.dart | services/stay.js | ✅ |
| 14 | 到家/离家检测 | map_screen.dart | services/home.js | ✅ |
| 15 | 低电量预警 | map_screen.dart | socket/handler.js | ✅ |
| 16 | 碰撞检测 | map_screen.dart | socket/handler.js | ✅ |
| 17 | 未活跃告警 | map_screen.dart | socket/handler.js | ✅ |
| 18 | 成员头像系统 | avatar_widget.dart | - | ✅ |
| 19 | 时间线 | timeline_screen.dart | routes/timeline.js | ✅ |
| 20 | 足迹记录 | footprint_screen.dart | routes/footprint.js | ✅ |

### P1 增强功能

| # | 功能 | 状态 |
|---|------|------|
| 21 | 位置分享链接 | ✅ |
| 22 | Emoji 炸弹 | ✅ |
| 23 | "想你"互动推送 | ✅ |
| 24 | Bark 推送通知 | ✅ |
| 25 | 本地通知 | ✅ |
| 26 | GPS 调试工具 | ✅ |
| 27 | 电池状态显示 | ✅ |
| 28 | 在线状态 | ✅ |
| 29 | 迷雾模式 | ✅ |
| 30 | 热力图 | ✅ |
| 31 | 世界迷雾 | ✅ |
| 32 | 定时位置共享 | ✅ |
| 33 | 行程记录 | ✅ |
| 34 | 轨迹皮肤 | ✅ |
| 35 | 昵称颜色 | ✅ |
| 36 | 隐身模式 | ✅ |
| 37 | 自定义头像 | ✅ |

### P2 可选功能

| # | 功能 | 状态 |
|---|------|------|
| 38 | 多语言 | ⏭ 跳过（仅中文） |

---

## 三、核心功能实现策略

### 3.1 GPS 定位策略

**Android — FusedLocationProvider**
```
问题：forceLocationManager: true 导致后台系统节流
修复：移除 forceLocationManager，使用 FusedLocationProvider（传感器融合）
速度精度：加速度计+陀螺仪+WiFi+基站综合计算，远优于纯GPS差分
```

**iOS — battery_plus 轮询**
```
问题：Timer.periodic 在后台暂停，电量更新迟滞
修复：每次位置上报前实时读取 batteryLevel + batteryState
超时保护：3秒超时防止 Future 永远不完成
```

### 3.2 位置滤波策略

**GPS 跳点过滤（双层）：**
1. **超速丢弃**：距离/时间 > 300km/h → 丢弃
2. **横跳丢弃**：距离 > 500m 且新精度更差 → 丢弃（解决关模拟软件后残留位置）

**围栏/Home 检测 — 连续确认机制：**
```
进入：连续 3 次（约15秒）在范围内才触发
离开：连续 3 次（约15秒）在范围外才触发
效果：单次 GPS 跳变不会触发误报，无需精度阈值
```

**速度 EWMA 滤波：**
```
α = 0.4（90%响应需~4步 vs 简单平均的9步）
精度 > 20m 时速度强制为 0（室内位置抖动不产生假速度）
```

### 3.3 位置上报策略

**自适应频率：**
| 运动状态 | 上报间隔 |
|----------|----------|
| 静止 | 60 秒 |
| 步行 | 15 秒 |
| 骑行 | 8 秒 |
| 驾车 | 5 秒 |

**上报内容：** 位置坐标 + 精度 + 速度 + 电量 + 充电状态

**防重复：** `_lastTimerSentPosition` 去重，坐标不变不重复发送

### 3.4 推送通知策略

**Bark 推送（POST 方式）：**
```
POST https://api.day.app/push
Body: { device_key, title, body, icon, group, sound }
图标：GitHub HTTPS raw URL（避免 iOS 不接受 HTTP 图标）
```

**全覆盖事件：**
SOS、围栏进入/离开、低电量、碰撞、未活跃、到家/离家、停留/离开、聊天消息、"想你"互动、emoji 炸弹

**定向 vs 广播：**
- "想你"：定向推送给目标用户（`targetUserId`）
- 聊天/SOS/围栏等：广播给同圈子成员（排除触发者）

### 3.5 本地缓存策略

**缓存层级：**
```
内存缓存 → 本地文件缓存 → 网络请求
```

| 缓存项 | 存储方式 | 更新策略 |
|--------|----------|----------|
| 深色模式 | SharedPreferences | 切换时写入，启动时读取 |
| 成员列表 | SharedPreferences (JSON) | API 刷新时写入，启动时先展示缓存 |
| 圈子列表 | SharedPreferences (JSON) | 同上 |
| 位置坐标 | SharedPreferences | 30秒防抖写入，启动时恢复地图 |
| 头像图片 | 本地文件（image_cache/） | 首次下载后缓存，7天过期清理 |

**启动流程：**
```
1. 读取深色模式缓存 → 立即设置主题（无白屏闪烁）
2. 读取位置缓存 → 立即移动地图并显示自己标记
3. 读取圈子/成员缓存 → 立即展示列表（可能略旧）
4. 后台 API 刷新 → 替换为最新数据
```

### 3.6 统一配置策略

所有服务器地址、端口、DNS 统一在 `lib/config.dart`：

```dart
class AppConfig {
  static const String serverHost = 'www.zhp98.fun';
  static const int httpPort = 8090;
  static const bool useHttps = false;
  static const String? customDns = '223.5.5.5';
}
```

更换域名只需改这一个文件。

---

## 四、容错与冗余策略

### 4.1 网络容错

| 场景 | 策略 |
|------|------|
| Socket 断连 | 指数退避重连（1s→2s→4s→...→30s） |
| HTTP 请求失败 | 10秒超时 + 状态码检查 |
| 离线位置 | 本地缓存位置坐标，联网后补传 |
| DNS 解析失败 | 系统 DNS → 自定义 DNS fallback |

### 4.2 数据容错

| 场景 | 策略 |
|------|------|
| 服务器时间 UTC | 前端 `DateTime.tryParse(str + 'Z').toLocal()` |
| 坐标系不一致 | WGS-84 → GCJ-02 转换（显示用 GCJ-02） |
| 数据库锁死 | sql.js 单进程，写操作 `run()` 封装 |
| 数据不一致 | 成员列表刷新时保留本地地址和实时电量 |

### 4.3 UI 容错

| 场景 | 策略 |
|------|------|
| 头像加载失败 | onError 静默降级为颜色+首字母 |
| GPS 未定位 | 显示缓存位置 + "GPS 搜索中..." |
| 无成员 | 显示引导按钮"邀请加入" |
| 服务端 401 | 自动清除 token，跳回登录页（防重入锁） |

### 4.4 通知冗余

- 本地通知（前台实时）+ Bark 推送（后台/锁屏）
- 同一事件双通道：Socket.io 实时 + HTTP REST 补偿
- 重复消息抑制：服务端事件节流（`checkEventThrottle`）

---

## 五、iOS 与 Android 差异处理

| 功能 | Android | iOS |
|------|---------|-----|
| 后台定位 | FusedLocationProvider + 前台服务 | Background Modes + 地理围栏 API |
| 电池获取 | battery_plus 原生 | battery_plus + 10秒轮询（前台），实时读取（上报时） |
| 通知 | flutter_local_notifications | flutter_local_notifications |
| 推送 | Bark | Bark（同 Android） |
| 云构建 | 本地 adb push | GitHub Actions IPA + TrollStore |
| DNS | 系统级 | 应用级 |

---

## 六、部署与运维

### 服务器信息
- **地址**：www.zhp98.fun
- **SSH**：端口 22，root 用户
- **项目路径**：/vol1/1000/9自己的软件项目/家庭位置共享/
- **API 端口**：8090
- **数据库**：familymap.db（sql.js，根目录）
- **日志**：/vol1/1000/fm.log
- **APK 下载**：http://192.168.31.234:2121/（本地调试服务器）

### 部署流程
1. 修改代码 → 推送 GitHub（Actions 自动构建 APK/IPA）
2. 上传 APK：paramiko → `/vol1/1000/app-debug.apk`
3. 重启服务器：paramiko → kill + nohup node server.js

### 高德 API Key
- Web服务：已配置在 `.env` 文件中（勿提交到版本控制）

### 已知限制
- VPS root 分区只读，只能写 /vol1
- PM2 不可用，用 nohup 直接运行
- GitHub HTTPS 不通，用 REST API + token 推送
- 无 Apple 开发者证书，iOS 通过 TrollStore 免签安装