---
AIGC:
  ContentProducer: '001191110102MAD55U9H0F10002'
  ContentPropagator: '001191110102MAD55U9H0F10002'
  Label: '1'
  ProduceID: 'f0839258-c0f8-4cda-b731-864cb1fbe7be'
  PropagateID: 'f0839258-c0f8-4cda-b731-864cb1fbe7be'
  ReservedCode1: '5cf0c7ab-5cee-4985-a245-6f68c1680485'
  ReservedCode2: '5cf0c7ab-5cee-4985-a245-6f68c1680485'
---

# FamilyMap 接续文档

> 最后更新：2026-06-27

本文档记录项目当前进度和待办事项，用于会话中断后快速接续工作。

---

## 一、项目概况

FamilyMap 是一款对标 Jagat（果汁）的位置共享应用，支持家人朋友间实时位置分享、围栏检测、语音聊天、停留检测等功能。

- **前端**：Flutter 3.44.1，Dart 3.12.1
- **后端**：Node.js + Express + Socket.io + sql.js
- **地图**：高德瓦片（暗色 `wprd0{s}` + style=7，亮色 `webrd0{s}` + style=8）
- **部署**：VPS `www.zhp98.fun:8090`，路径 `/vol1/1000/9自己的软件项目/家庭位置共享/`
- **iOS**：GitHub Actions 云构建 IPA，TrollStore 免签安装
- **仓库**：https://github.com/sleep1234/FamilyMap

---

## 二、已完成的核心功能（38项中37项）

### 2.1 位置共享
- [x] 实时位置共享（Socket.io）
- [x] 后台位置追踪（Android FusedLocationProvider / iOS 后台模式）
- [x] 自适应上报频率（静止/步行/骑行/驾车不同间隔）
- [x] 拖尾粒子效果（根据速度自适应密度）
- [x] WGS-84 ↔ GCJ-02 坐标转换
- [x] GPS 跳点过滤（超速丢弃 + 横跳丢弃）

### 2.2 围栏与检测
- [x] 地理围栏（进入/离开检测）
- [x] Home 检测（到家/离家）
- [x] 停留检测（停留类型识别 + 10分钟通知阈值）
- [x] 连续确认机制（3次确认防跳变）

### 2.3 通信
- [x] 圈子群聊（文字 + 语音消息）
- [x] 语音录制（微信风格交互）
- [x] "想你"互动推送（定向推送）
- [x] Emoji 炸弹

### 2.4 通知
- [x] Bark 推送（SOS、围栏、低电量、碰撞、到家离家、聊天、想你、停留离开）
- [x] 本地通知（前台）
- [x] 推送图标（自定义 FamilyMap 图标，HTTPS GitHub raw URL）

### 2.5 其他
- [x] 多圈子管理
- [x] SOS 紧急求救
- [x] 低电量预警
- [x] 碰撞检测
- [x] 未活跃告警
- [x] 深色模式
- [x] 逆地理解码（高德 API）
- [x] 分享链接
- [x] 足迹记录

### 2.6 跳过
- [ ] 多语言（仅中文，用户确认不需要）

---

## 三、今日会话进度（2026-06-18/19）

### 已完成
| 问题 | 修复方案 | 文件 |
|------|----------|------|
| 停留通知频率过高 | 添加 10 分钟最低时长阈值 | `config.js`, `services/stay.js` |
| Bark Key 保存失败 | `users.js` 重复路由抢先匹配，删除重复 | `routes/users.js` |
| "想你"没有 Bark 推送 | `interaction:care` 加 Bark 推送 | `services/bark.js`, `socket/handler.js` |
| 群聊消息无 Bark 推送 | `chat.js` 加 `notifyChat` | `routes/chat.js`, `services/bark.js` |
| 所有通知缺 Bark 推送 | 停留/离开、到家/离家、emoji 炸弹全部加上 | `services/stay.js`, `services/home.js`, `socket/handler.js` |
| iOS 电池后台不更新 | 每次位置上报时实时读电量 | `map_screen.dart` |
| iOS 电量更新迟滞 | `_handlePositionUpdate` 改 async，上报前实时读 battery_plus | `map_screen.dart` |
| 关模拟后位置反复横跳 | 500m+低精度横跳过滤器 | `map_screen.dart` |
| 室内精度差导致速度乱跳 | 去掉 accuracy>20m 硬拒，精度差时速度置零 | `map_screen.dart` |
| home/围栏边界跳动 | 3 次连续确认机制 | `services/home.js`, `services/geofence.js` |
| "想你"广播给所有人 | 定向推送，传 targetUserId | `map_screen.dart`, `socket_service.dart`, `socket/handler.js` |
| 头像全部消失 | `$AppConfig.httpBaseUrl` 字符串插值缺花括号 | `avatar_widget.dart`, `member_marker.dart` |
| 服务器地址分散 | 统一到 `lib/config.dart` | 全局替换 |
| iOS 构建无自定义 DNS | 添加 `dns_http_client.dart`（简化版） | `lib/utils/` |
| 启动白屏（深色模式） | 深色模式本地缓存 | `main.dart` |
| 启动空白等待（成员列表） | 成员列表+圈子本地缓存 | `map_screen.dart`, `local_cache_service.dart` |
| 头像每次重新下载 | 图片本地文件缓存 | `image_cache_service.dart`, `avatar_widget.dart`, `member_marker.dart` |
| 数据刷新慢 | 下拉刷新 + 刷新按钮 | `map_screen.dart` |
| 启动慢（通知阻塞） | 通知初始化改非阻塞，不等待结果 | `map_screen.dart` |
| 启动慢（GPS超时15s） | GPS超时从15s降到8s | `map_screen.dart` |
| 围栏每次启动走网络 | 围栏添加本地缓存 | `local_cache_service.dart`, `map_screen.dart` |
| 用户设置每次启动走网络 | 用户设置添加本地缓存 | `local_cache_service.dart`, `map_screen.dart` |
| 逆地理编码无缓存 | 客户端逆地理结果添加本地缓存 | `local_cache_service.dart`, `map_screen.dart` |
| 缓存路径仍发围栏请求 | 缓存路径跳过围栏网络请求 | `map_screen.dart` |
| 图片内存缓存无上限 | 添加LRU淘汰，限制200条 | `image_cache_service.dart` |
| 图片过期缓存未清理 | 启动时调用cleanExpired | `main.dart`, `image_cache_service.dart` |
| 每图片新建HttpClient | 复用全局HttpClient | `image_cache_service.dart` |
| locations表无限增长 | 添加30天清理+每日定时清理 | `db.js`, `server.js` |
| 缺失circle_members索引 | 添加circle_id索引 | `db.js` |
| 位置更新多次DB查询 | 合并用户信息查询为单次JOIN | `socket/handler.js` |

### 进行中 / 待验证
| 问题 | 状态 | 说明 |
|------|------|------|
| Bark Key 保存（iOS） | 已修复待验证 | 服务器路由已修复，需用户测试 |
| Bark 图标显示 | 已修复 | 用 GitHub HTTPS raw URL |
| iOS 后台电量更新 | 已修复 | 每次位置上报前实时读取 |
| 启动速度优化 | 已实施 | 通知非阻塞+GPS超时缩短+缓存层 |
| ETA 到达时间 | 已修复 | 服务端添加 distanceKm 字段，PM2 重启生效 |
| 粒子拖尾动画 | 已实现 | ±12度扇形喷射+地面线条，所有速度统一 |
| 脉冲呼吸灯 | 已实现 | 在线成员脉冲光环 |
| 围栏缓存 | 已修复 | API 刷新时也会加载围栏 |

---

## 三-B、今日会话进度（2026-06-27）

### 已完成
| 问题 | 修复方案 | 文件 |
|------|----------|------|
| Android 打开闪退 | `KeepAliveService` 在 `foregroundServiceType="location"` 下需位置权限，`onCreate()` 时权限未授予导致 `MissingForegroundServiceTypeException`。改为检查权限后再启动 | `android/.../MainActivity.kt` |
| iOS 登录后闪回登录页 | 服务端登录失败返回 401，`_checkStatus` 统一抛 `AuthExpiredException`，`_handleSubmit` 的 `on AuthExpiredException` 先于 `catch` 执行，吞掉了"密码错误"提示直接跳登录页。改为在 `AuthExpiredException` 中检查错误内容 | `lib/main.dart` |
| 覆盖安装后不显示在线 | 旧 token 被其他设备登录删除，Socket 用无效 token 无限重连无通知。新增 `onAuthFailed` 事件，`connect_error` 中检测认证失败后断开并通知上层 | `lib/services/socket_service.dart`, `lib/screens/map_screen.dart` |
| iOS CI 编译失败 | Flutter 3.44 + 新版 Xcode 需要 `CODE_SIGN_STYLE = Manual` + 空 `DEVELOPMENT_TEAM`，仅靠 `--no-codesign` 不够 | `ios/Runner.xcodeproj/project.pbxproj` |
| Android CI 编译失败 | `socket_io_client 3.x` 中 `Socket.reconnection` 不是 setter，改为 `disconnect()` + 置 null | `lib/services/socket_service.dart` |

---

## 四、服务器部署要点

### 服务器使用 PM2 管理！
```bash
# 查看状态
pm2 list

# 重启
pm2 restart familymap --update-env -f

# 查看日志
pm2 logs familymap
```

### 关键路径
- 项目目录：`/vol1/1000/9自己的软件项目/家庭位置共享/`
- 数据库：`/vol1/1000/9自己的软件项目/家庭位置共享/familymap.db`
- 日志：`pm2 logs familymap`
- 构建产物：`build_output/` 目录下（APK/IPA 从 GitHub Actions 下载）

### 部署方式
使用 PM2 管理服务进程。`ecosystem.config.js` 已配置环境变量（端口、高德 Key、SSL 证书路径等）。
GitHub Actions 自动构建 APK/IPA，用 `gh run download` 下载到本地。

### 注意事项
- VPS root 分区只读，日志和数据只能写 `/vol1`
- PM2 已可用，使用 `ecosystem.config.js` 管理
- GitHub Actions 云构建 APK/IPA，用 `gh run download` 下载

---

## 五、下次接续注意事项

1. **验证 Android 闪退修复**：让用户安装新版 APK 确认启动不再闪退
2. **验证 iOS 登录修复**：让用户确认输入错误密码时能看到提示，不再闪回登录页
3. **验证覆盖安装场景**：在另一设备登录后，旧设备应自动跳转到登录页
4. **Bark 推送验证**：让用户确认 iOS 上 Bark Key 保存和推送是否正常
5. **多设备登录退出**：已实现 force_logout + connect_error 双重检测