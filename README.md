---
AIGC:
  ContentProducer: '001191110102MAD55U9H0F10002'
  ContentPropagator: '001191110102MAD55U9H0F10002'
  Label: '1'
  ProduceID: '91a5a423-2e8d-4a96-aeda-b100b9a45d9b'
  PropagateID: '91a5a423-2e8d-4a96-aeda-b100b9a45d9b'
  ReservedCode1: 'dfb44453-cf04-41dd-a318-31b95f93da15'
  ReservedCode2: 'dfb44453-cf04-41dd-a318-31b95f93da15'
---

# FamilyMap — 家人朋友实时位置共享

对标 Jagat（果汁）的轻量化位置共享应用。家人朋友之间互相看到彼此的实时位置、移动拖尾、停留信息、围栏告警等，用 Flutter + Node.js 全栈实现。

---

## 目录

- [功能概览](#功能概览)
- [技术架构](#技术架构)
- [项目结构](#项目结构)
- [环境要求](#环境要求)
- [快速开始](#快速开始)
- [后端 API 文档](#后端-api-文档)
- [Socket.io 实时事件](#socketio-实时事件)
- [坐标系说明](#坐标系说明)
- [开发辅助工具：文件管理服务](#开发辅助工具文件管理服务)
- [部署指南](#部署指南)
- [常见问题与已知坑](#常见问题与已知坑)

---

## 功能概览

### 核心功能

| 功能 | 说明 |
|------|------|
| 实时位置共享 | GPS 定位 + Socket.io 实时推送，支持后台持续追踪 |
| 移动拖尾特效 | 沿路径的渐变拖尾带，头部亮色到尾部暗色，速度自适应宽度 |
| 停留检测 | 自动识别停留地点，显示停留地址和时长，实时递增 |
| 围栏告警（Geofence） | 地图长按创建围栏，成员进出时推送通知 |
| 碰撞检测 | 9点滑动窗口 + 多重确认，过滤 GPS 毛刺避免误报 |
| 行程分享 | 生成分享链接，Web 页面实时查看行程轨迹（5s 轮询） |
| 表情炸弹 | 点对点发送 emoji 动画（心、烟花、握手等） |
| 心情状态 | 类似 Jagat 的心情标签（到家了、工作中、睡觉中等） |
| 睡眠模式 | 睡觉时头像显示月亮角标，状态显示"睡觉中" |
| SOS 求助 | 一键 SOS，圈子内所有人收到紧急通知 |
| 围栏圈子 | 创建/加入圈子，邀请码加入，同一圈子成员互相可见 |

### 位置与地图

| 功能 | 说明 |
|------|------|
| 高德瓦片地图 | 亮色/暗色双主题，支持缩放 |
| 逆地理解码 | 调用高德 API，服务端缓存防重复请求 |
| 活动识别 | Android Activity Recognition 判断步行/骑行/驾车/静止 |
| 自适应上报频率 | 驾车 4s、步行/骑行 10s、静止 30s |
| 速度滑动窗口 | 9 点窗口过滤 GPS 噪声，低精度(>50m)数据排除 |
| GPS 跳点检测 | 150km/h 以上速度差异自动丢弃 |
| GPS 调试浮窗 | 实时显示精度/速度/坐标/初始化状态，可导出 CSV |

### 社交与互动

| 功能 | 说明 |
|------|------|
| 圈内聊天 | 文字消息，支持实时发送 |
| 足迹回顾 | 查看历史位置足迹时间线 |
| 到达/离家通知 | 检测到家/离家状态变更，推送到圈子 |
| 幽灵模式 | 隐身（完全隐藏）或模糊位置（显示大致区域） |
| 电量显示 | 显示成员手机电量和充电状态 |
| 世界地图 | 全局概览所有圈子成员位置 |
| 紧急联系人 | 设置紧急联系人，SOS 时通知 |

### 数据功能

| 功能 | 说明 |
|------|------|
| 热力图 | 近 7 天位置热力图可视化 |
| GPX 导出 | 导出轨迹为标准 GPX 格式 |
| ETA 预估 | 调用高德驾车路线 API 预估到达时间 |
| 驾驶评分 | 基于急刹/急加速事件评分 |
| 联系人管理 | 添加/删除联系人 |

---

## 技术架构

```
┌─────────────────────────────────────────────┐
│          Flutter App (Android / iOS)         │
│                                             │
│  map_screen.dart ──── Socket.io Client      │
│  settings_screen.dart ─── HTTP REST         │
│  chat_screen.dart                           │
│  footprint_screen.dart                      │
│  timeline_screen.dart                       │
│                                             │
│  Services:                                  │
│  ├── socket_service.dart (实时通信)          │
│  ├── api_service.dart (REST API)            │
│  └── gps_debug_logger.dart (GPS调试)        │
│                                             │
│  Widgets:                                   │
│  ├── member_marker.dart (成员标记+动画)      │
│  └── trail_particles.dart (拖尾特效渲染)     │
└────────────────────┬────────────────────────┘
                     │ Socket.io / HTTP
                     ▼
┌─────────────────────────────────────────────┐
│         Node.js Server (Express + Socket.io) │
│                                             │
│  server.js (~1500行, 全部后端逻辑)           │
│  ├── Express REST API (40+ 端点)            │
│  ├── Socket.io 实时推送                      │
│  ├── sql.js 嵌入式数据库 (SQLite)           │
│  ├── 高德逆地理解码 + 服务端缓存             │
│  ├── 碰撞检测引擎                           │
│  ├── 停留检测引擎                           │
│  ├── 围栏进出检测                           │
│  └── 行程分享页面 (服务端渲染 HTML)          │
└─────────────────────────────────────────────┘

┌─────────────────────────────────────────────┐
│      开发辅助: upload_server.py              │
│  Python HTTP 服务，APK下载+截图上传+文本传输 │
└─────────────────────────────────────────────┘
```

---

## 项目结构

```
FamilyMap/
├── server.js                  # 后端主文件（REST API + Socket.io + 全部业务逻辑）
├── package.json               # Node.js 依赖
├── upload_server.py           # 开发辅助：文件管理 HTTP 服务
├── build_apk.bat              # Windows 一键编译脚本
├── pubspec.yaml               # Flutter 依赖配置
├── android/                   # Android 原生配置
│   └── app/src/main/
│       ├── AndroidManifest.xml
│       └── kotlin/.../MainActivity.kt
├── ios/                       # iOS 原生配置
│   ├── Podfile                # CocoaPods 依赖
│   ├── Runner/
│   │   ├── AppDelegate.swift  # 应用入口
│   │   ├── Info.plist         # 权限声明（位置/通知/运动/相机等）
│   │   └── SceneDelegate.swift
│   └── Runner.xcodeproj/
├── lib/                       # Flutter 应用代码
│   ├── main.dart              # 入口（暗黑模式、路由）
│   ├── models/
│   │   └── models.dart        # 数据模型（AppUser, MemberLocation, UserSettings 等）
│   ├── screens/
│   │   ├── map_screen.dart    # 主地图页（~3100行，核心界面）
│   │   ├── settings_screen.dart # 设置页
│   │   ├── chat_screen.dart     # 聊天页
│   │   ├── footprint_screen.dart# 足迹页
│   │   └── timeline_screen.dart # 时间线页
│   ├── services/
│   │   ├── socket_service.dart  # Socket.io 通信层
│   │   ├── api_service.dart     # REST API 通信层
│   │   └── gps_debug_logger.dart# GPS 调试日志
│   └── widgets/
│       ├── member_marker.dart   # 地图成员标记（动画+在线/离线状态）
│       └── trail_particles.dart # 拖尾特效（Jagat 风格路径拖尾带）
├── deploy/                    # VPS 部署辅助脚本
└── FamilyMap功能清单与实现路径.docx  # 38项功能详细设计文档
```

---

## 环境要求

### 开发环境

| 工具 | 版本 |
|------|------|
| Flutter | 3.44.1 |
| Dart | 3.12.1 |
| Node.js | 18+ |
| Python | 3.8+（仅 upload_server.py 需要） |
| Android SDK | API 24~36 |
| Xcode | 15+ (iOS 构建) |
| CocoaPods | iOS 原生插件依赖管理 |

### 第三方服务

| 服务 | 用途 | 配置方式 |
|------|------|----------|
| 高德 Web 服务 API | 逆地理解码 | 环境变量 `AMAP_KEY` |
| 高德瓦片 | 地图底图 | 代码内硬编码瓦片 URL |

### Flutter 依赖

```yaml
dependencies:
  flutter_map: ^7.0.2         # 地图（高德瓦片）
  latlong2: ^0.9.1            # 坐标处理
  socket_io_client: ^3.0.2    # 实时通信
  http: ^1.2.1                # REST API
  geolocator: ^13.0.2         # GPS 定位
  provider: ^6.1.2            # 状态管理
  shared_preferences: ^2.3.3  # 本地存储
  flutter_slidable: ^3.1.1    # 滑动操作
  share_plus: ^10.1.4         # 分享
  uuid: ^4.5.1                # 唯一ID
  intl: ^0.20.1               # 国际化
  crypto: ^3.0.3              # 加密
  activity_recognition_flutter: ^6.0.0  # 活动识别（需 NSMotionUsageDescription）
  polylabel: ^1.0.1           # 多边形极点
  path_provider: ^2.1.5       # 文件路径
  battery_plus: ^7.0.0        # 电池状态
  flutter_local_notifications: ^22.0.0  # 本地通知
  image_picker: ^1.2.2        # 图片选择
  record: ^7.1.0              # 录音
  audioplayers: ^6.7.1        # 音频播放
  flutter_app_badger: ^1.5.0  # 桌面角标
```

### Node.js 依赖

```json
{
  "express": "^4.18.2",
  "socket.io": "^4.7.2",
  "sql.js": "^1.10.3",
  "docx": "^9.7.1"
}
```

---

## 快速开始

### 1. 启动后端

```bash
# 安装依赖
npm install

# 设置高德 API Key
export AMAP_KEY=你的高德Key

# 启动服务
PORT=8090 node server.js
```

服务启动后默认在 `http://localhost:8090` 。

### 2. 启动 Flutter 应用

```bash
# 安装依赖
flutter pub get

# 编译运行（Debug）
flutter run

# 或编译 APK
flutter build apk --debug
```

### 3. 修改 API 地址

在 `lib/services/api_service.dart` 和 `lib/services/socket_service.dart` 中修改服务器地址：

```dart
// 示例：指向你的服务器
static const String baseUrl = 'http://你的IP:8090';
```

---

## 后端 API 文档

### 用户系统

| 方法 | 路径 | 说明 |
|------|------|------|
| POST | `/api/register` | 注册（username, password, name） |
| POST | `/api/login` | 登录，返回用户信息 |
| GET | `/api/users/:userId` | 获取用户信息 |
| PUT | `/api/users/:userId` | 更新用户信息（name, avatar_color, mood, is_sleeping, ghost_mode, nickname_color） |

### 圈子

| 方法 | 路径 | 说明 |
|------|------|------|
| POST | `/api/circles` | 创建圈子 |
| POST | `/api/circles/join` | 通过邀请码加入圈子 |
| GET | `/api/users/:userId/circles` | 获取用户所有圈子 |
| GET | `/api/circles/:circleId/members` | 获取圈子成员列表（含位置、电量、停留信息） |

### 位置

| 方法 | 路径 | 说明 |
|------|------|------|
| GET | `/api/users/:userId/locations` | 获取位置历史 |
| GET | `/api/geocode?lat=&lng=` | 逆地理解码（高德 API + 服务端缓存） |
| GET | `/api/users/:userId/stays` | 获取停留记录 |
| GET | `/api/users/:userId/timeline` | 获取时间线 |
| GET | `/api/users/:userId/track` | 获取轨迹（可选时间范围） |
| GET | `/api/users/:userId/heatmap?days=7` | 热力图数据 |
| GET | `/api/users/:userId/driving-score` | 驾驶评分 |

### 围栏

| 方法 | 路径 | 说明 |
|------|------|------|
| GET | `/api/circles/:circleId/geofences` | 获取围栏列表 |
| POST | `/api/circles/:circleId/geofences` | 创建围栏 |
| DELETE | `/api/geofences/:id` | 删除围栏 |

### SOS

| 方法 | 路径 | 说明 |
|------|------|------|
| POST | `/api/sos` | 发起 SOS |
| PUT | `/api/sos/:id/resolve` | 解除 SOS |

### 聊天

| 方法 | 路径 | 说明 |
|------|------|------|
| GET | `/api/circles/:circleId/messages` | 获取消息历史 |
| POST | `/api/circles/:circleId/messages` | 发送消息 |

### 足迹

| 方法 | 路径 | 说明 |
|------|------|------|
| GET | `/api/users/:userId/footprints` | 获取足迹 |
| POST | `/api/users/:userId/footprints` | 添加足迹 |
| DELETE | `/api/footprints/:id` | 删除足迹 |

### 联系人 & 紧急联系人

| 方法 | 路径 | 说明 |
|------|------|------|
| POST | `/api/contacts` | 添加联系人 |
| DELETE | `/api/contacts/:userId/:contactId` | 删除联系人 |
| GET | `/api/users/:userId/contacts` | 获取联系人列表 |
| GET | `/api/users/:userId/emergency-contacts` | 获取紧急联系人 |
| POST | `/api/users/:userId/emergency-contacts` | 添加紧急联系人 |
| DELETE | `/api/emergency-contacts/:id` | 删除紧急联系人 |

### 设置 & 其他

| 方法 | 路径 | 说明 |
|------|------|------|
| GET | `/api/users/:userId/settings` | 获取用户设置 |
| PUT | `/api/users/:userId/settings` | 更新设置（暗黑模式、共享暂停等） |
| GET | `/api/users/:userId/world` | 世界地图数据 |
| GET | `/api/eta?from=&to=` | ETA 到达预估（高德驾车路线） |
| POST | `/api/share-link` | 生成行程分享链接 |
| GET | `/share/:token` | 分享页面 HTML |
| GET | `/api/share/:token` | 分享页面数据 API |
| GET | `/api/users/:userId/export/gpx` | 导出 GPX 轨迹 |

### 管理接口

| 方法 | 路径 | 说明 |
|------|------|------|
| POST | `/api/admin/refresh-geocode-cache` | 强制刷新逆地理缓存 |
| GET | `/api/admin/geocode-stats` | 缓存统计 |

---

## Socket.io 实时事件

### 客户端发送

| 事件 | 数据 | 说明 |
|------|------|------|
| `user:online` | `{userId, circleId}` | 上线通知 |
| `location:update` | `{userId, latitude, longitude, accuracy, speed, battery_level, is_charging}` | 位置更新 |
| `emoji:bomb` | `{from, to, emoji}` | 发送表情炸弹 |
| `interaction:care` | `{from, to, type}` | 关怀互动 |

### 服务端推送

| 事件 | 数据 | 说明 |
|------|------|------|
| `member:location` | `{userId, latitude, longitude, ...}` | 成员位置更新 |
| `member:online` | `{userId}` | 成员上线 |
| `member:offline` | `{userId}` | 成员离线 |
| `collision:alert` | `{userId, ...}` | 碰撞告警 |
| `geofence:enter` | `{userId, geofenceId, name}` | 进入围栏 |
| `geofence:exit` | `{userId, geofenceId, name}` | 离开围栏 |
| `home:status` | `{userId, status: 'arrived'|'left', address}` | 到家/离家 |
| `stay:update` | `{userId, address, minutes, startedAt}` | 停留更新 |
| `sos:alert` | `{userId, circleId, ...}` | SOS 告警 |
| `emoji:received` | `{from, emoji}` | 收到表情 |
| `care:received` | `{from, type}` | 收到关怀 |

---

## 坐标系说明

GPS 返回的是 **WGS-84** 坐标，高德地图使用 **GCJ-02** 坐标（国测局偏移）。

本项目处理方案：
- **服务端**：存储 WGS-84 原始坐标
- **Flutter 端**：接收后立即转为 GCJ-02 用于地图显示
- **分享链接**：Flutter 发送的坐标已是 GCJ-02，API 从数据库读的是 WGS-84 需要转换（用 `isGcj02` 标志区分）
- 转换函数：`_wgs84ToGcj02()` 在 Flutter 和 server.js 中各有一份

**重要**：高德暗色瓦片必须用 `wprd0{s}.is.autonavi.com` 域名 + `style=7`，`webrd` 域名不支持暗色样式（返回 404）。

---

## 开发辅助工具：文件管理服务

`upload_server.py` 是一个独立的 Python HTTP 服务，用于开发期间的跨设备协作。当手机和电脑在同一局域网时，可以通过它：

- 从手机下载编译好的 APK
- 从手机上传截图/日志到电脑
- 在手机和电脑之间传输文本片段

### 启动方式

```bash
python upload_server.py
```

默认端口 `2121`，启动后会显示局域网 IP：

```
  ╔══════════════════════════════════════╗
  ║   FamilyMap 文件管理服务已启动       ║
  ╠══════════════════════════════════════╣
  ║  局域网: http://192.168.x.x:2121     ║
  ║  本机:   http://127.0.0.1:2121      ║
  ╚══════════════════════════════════════╝
```

手机浏览器打开 `http://电脑IP:2121` 即可使用。

### 功能列表

| 功能 | 说明 |
|------|------|
| APK 一键下载 | 首页大按钮直接下载最新 `app-debug.apk`，支持断点续传 |
| 文件上传 | 点击或拖拽上传截图、日志等任意文件 |
| 构建产物浏览 | 列出 `build/` 目录下的 APK 和其他编译产物 |
| 已上传文件浏览 | 列出 `uploads/` 目录下的文件，点击可下载 |
| 文本传输 | 输入文本发送到电脑，手机和电脑之间快速复制粘贴 |
| 多线程并发 | ThreadingMixIn，多人同时下载不阻塞 |
| Range/断点续传 | 支持 HTTP Range 请求，大文件下载可中断恢复 |

### 技术细节

- **多线程**：`ThreadingMixIn + HTTPServer`，每个请求独立线程
- **断点续传**：解析 `Range: bytes=start-end` 请求头，返回 `206 Partial Content`
- **文件上传**：解析 `multipart/form-data`，自动加时间戳防重名
- **文本传输**：POST 到 `/text` 保存为 `.txt` 文件，GET `/api/texts` 返回最近 20 条 JSON
- **零依赖**：仅用 Python 标准库，无需安装额外包

### 目录结构

```
uploads/              # 上传文件存储目录
uploads/texts/        # 文本片段存储目录
build/app/outputs/flutter-apk/  # APK 构建产物（服务读取）
```

---

## 部署指南

### VPS 部署（推荐 PM2）

```bash
# 1. 上传 server.js 和 package.json 到服务器
scp server.js package.json root@你的服务器:/path/to/app/

# 2. SSH 到服务器
ssh root@你的服务器

# 3. 安装依赖
cd /path/to/app/
npm install

# 4. PM2 启动
AMAP_KEY=你的Key PORT=8090 pm2 start server.js --name familymap

# 5. 保存 PM2 进程列表（开机自启）
pm2 save
pm2 startup
```

### 自动部署脚本

项目内含部署脚本（位于 `.temp/deploy2.py`，使用 paramiko），可一键上传 server.js 到 VPS 并重启 PM2。

> 注意：部署脚本包含服务器密码等敏感信息，已加入 .gitignore 不会提交到仓库。

### Flutter 编译发布

```bash
# Debug 版本（快速测试）
flutter build apk --debug

# Release 版本（正式发布，需签名）
flutter build apk --release
```

编译产物在 `build/app/outputs/flutter-apk/app-debug.apk`。

---

## 常见问题与已知坑

### iOS 相关

1. **安装后闪退**：Info.plist 不能包含无效 key（如 `UIUserNotificationSettings`），`activity_recognition_flutter` 必须声明 `NSMotionUsageDescription`
2. **通知不显示**：`DarwinInitializationSettings` 中 `requestAlertPermission` 必须为 `true`，并需通过 `IOSFlutterLocalNotificationsPlugin` 显式请求权限
3. **Podfile 缺失**：原生插件（geolocator、battery_plus 等）需要 CocoaPods 依赖，`flutter pub get` 后需在 `ios/` 目录执行 `pod install`
4. **Bark 推送超时**：后台推送依赖 Bark 服务，需在 App 设置中配置 Bark Key

### Flutter 相关

5. **中文路径崩溃**：Flutter 分析器在包含中文的路径下会崩溃，项目路径必须全英文。
6. **`ListView.builder(shrinkWrap: true)` + 动画列表项**：会导致 Sliver assertion 崩溃，改用 `SingleChildScrollView` + `Column`。
7. **`AnimationController` 在频繁重建的列表项中**：导致 `_elements.contains(element)` 崩溃，改用隐式动画组件。
8. **`AnimatedBuilder` 冲突**：Flutter 内置了 `AnimatedBuilder`，自定义的需要改名为 `TrailAnimatedBuilder`。
9. **成员卡片溢出**：`ListTile` 的 subtitle Column 内容过多时溢出，需改用手动 `Row` + `Expanded` 布局。

### GPS 相关

6. **GPS 初始化静默失败**：老版本在权限拒绝/超时时直接 return 不启动位置流，已修复为始终启动位置流并自动重试。
7. **`distanceFilter > 0`**：设为 0 让每次 GPS 更新都触发，避免静止时收不到数据。
8. **GPS 调试框依赖 `GpsDebugLogger`**：老版本只在调试开关开启时记录快照，已修复为始终更新 `currentSnapshot`。

### 地图相关

9. **高德暗色瓦片 404**：必须用 `wprd0{s}.is.autonavi.com` + `style=7`，`webrd` 域名不支持暗色样式。
10. **坐标双倍转换**：分享链接中 Flutter 发来的是已转换的 GCJ-02，数据库存的是 WGS-84，需要用 `isGcj02` 标志区分。

### 后端相关

11. **碰撞检测误报**：GPS 速度毛刺 + 上报间隔不均匀 + 静止时假急刹。修复：9 点滑动窗口 + 精度>50m 过滤 + 双重确认 + 60m/s 高速阈值 + 3 分钟冷却。
12. **停留检测误报**：高速移动时每 4s 新点与停留点距离 >200m，反复创建/结束停留。修复：速度 >3m/s 跳过停留操作 + 离开双重确认。
13. **sql.js 数据库**：嵌入式 SQLite，数据存在单个 `.db` 文件中，需定期保存到磁盘（有防抖定时器）。

---

## License

MIT

> AI生成