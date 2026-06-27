---
AIGC:
  ContentProducer: '001191110102MAD55U9H0F10002'
  ContentPropagator: '001191110102MAD55U9H0F10002'
  Label: '1'
  ProduceID: 'fee456e8-53fc-4ea0-9edd-4693dc71bcc0'
  PropagateID: 'fee456e8-53fc-4ea0-9edd-4693dc71bcc0'
  ReservedCode1: 'ab098989-4616-49ba-ac94-7478fa2726ad'
  ReservedCode2: 'ab098989-4616-49ba-ac94-7478fa2726ad'
---

# 服务器配置说明

本文档说明如何修改 FamilyMap 的服务器地址、端口、DNS 等配置。

## 快速修改

### 修改服务器域名/端口

编辑 `lib/config.dart`：

```dart
class AppConfig {
  // ==================== 服务器配置 ====================
  
  /// 服务器域名（不带协议和端口）
  static const String serverHost = 'your-domain.com';  // ← 修改这里
  
  /// HTTP 端口
  static const int httpPort = 8090;  // ← 修改这里
  
  /// WebSocket 端口（与 HTTP 相同）
  static const int wsPort = 8090;  // ← 修改这里
  
  /// 是否使用 HTTPS
  static const bool useHttps = false;  // ← 修改这里（如果用 HTTPS 改为 true）
}
```

### 修改 DNS 服务器

```dart
class AppConfig {
  // ==================== DNS 配置 ====================
  
  /// 自定义 DNS 服务器
  /// 设为 null 则使用系统默认 DNS
  static const String? customDns = '223.5.5.5';  // ← 修改这里（阿里云 DNS）
}
```

## 配置文件位置

| 文件 | 用途 |
|------|------|
| `lib/config.dart` | **主要配置文件** - 所有服务器地址、端口、DNS 配置 |
| `server/config.js` | 后端配置 - 环境变量、功能开关 |
| `server/.env` | 后端环境变量 - 数据库路径、密钥等 |

## 修改域名完整步骤

### 1. 修改 Flutter 客户端

编辑 `lib/config.dart`：

```dart
static const String serverHost = 'new-domain.com';
static const int httpPort = 8090;
static const bool useHttps = false;
```

### 2. 修改服务器环境变量

SSH 到服务器，编辑 `.env` 文件：

```bash
cd /vol1/1000/9自己的软件项目/家庭位置共享
nano .env
```

修改 `ALLOWED_ORIGINS` 为新域名：

```env
ALLOWED_ORIGINS=http://new-domain.com:8090
```

### 3. 重新部署

**客户端**：
```bash
flutter pub get
flutter build apk --debug
```

**服务器**：
```bash
cd /vol1/1000/9自己的软件项目/家庭位置共享
bash -c "set -a; source .env; set +a; nohup node server.js >> /vol1/1000/fm.log 2>&1 &"
```

## DNS 配置说明

### 自定义 DNS 的作用

- 绕过运营商 DNS 劫持
- 使用更可靠的 DNS 服务器
- 加快域名解析速度

### 当前配置

- **DNS 服务器**：223.5.5.5（阿里云 DNS）
- **适用场景**：域名从阿里云购买时使用

### 修改 DNS

```dart
static const String? customDns = '8.8.8.8';  // Google DNS
// 或
static const String? customDns = '114.114.114.114';  // 114 DNS
// 或
static const String? customDns = null;  // 使用系统默认 DNS
```

## 服务器配置文件

### server/config.js

```javascript
module.exports = {
  // 功能开关
  STAY_SPEED_THRESHOLD: 1.5,      // 停留检测速度阈值 (m/s)
  STAY_DRIFT_TOLERANCE: 30,       // 停留位置漂移容忍度 (m)
  STAY_NOTIFY_MIN_DURATION: 10,   // 停留通知最小持续时间 (分钟)
  ALIVE_WARNING_HOURS: 24,        // 长时间未活跃警告 (小时)
  LOW_BATTERY_THRESHOLD: 20,      // 低电量阈值 (%)
  // ... 更多配置
};
```

### server/.env

```env
# 数据库
DB_PATH=./familymap.db

# CORS 白名单（逗号分隔）
ALLOWED_ORIGINS=http://localhost:8090,http://127.0.0.1:8090

# JWT 密钥
JWT_SECRET=your-secret-key

# 高德 API Key
AMAP_KEY=your-amap-key
```

## 常见问题

### Q: 修改域名后无法连接

A: 检查以下几点：
1. `config.dart` 中的域名是否正确
2. 服务器 `.env` 中的 `ALLOWED_ORIGINS` 是否包含新域名
3. 域名 DNS 是否已解析到服务器 IP
4. 防火墙是否开放了对应端口

### Q: DNS 解析失败

A: 尝试以下方案：
1. 将 `customDns` 设为 `null` 使用系统 DNS
2. 检查 DNS 服务器地址是否正确
3. 测试网络连接：`ping 223.5.5.5`

### Q: 如何测试配置是否生效

A: 使用调试工具：
1. 在 App 中开启 GPS 调试窗口
2. 查看网络请求日志
3. 检查服务器访问日志

## 文件结构

```
FamilyMap/
├── lib/
│   ├── config.dart           # 主配置文件（客户端）
│   ├── services/
│   │   ├── api_service.dart   # API 服务（使用 AppConfig）
│   │   └── socket_service.dart # Socket 服务（使用 AppConfig）
│   └── utils/
│       └── dns_http_client.dart # 自定义 DNS 解析
├── server/
│   ├── config.js              # 服务器配置
│   └── .env                   # 环境变量
└── SERVER_CONFIG.md           # 本文档
```