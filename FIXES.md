# FamilyMap 代码审查修复指南

本文件列出所有需要在 `server.js` 中进行的修改。请按顺序应用。

---

## 修复清单

### 修复 1: 密码哈希升级 (SHA-256 → bcryptjs)

**问题**: SHA-256 + 固定盐值不适合密码存储

**说明**: 使用 `bcryptjs`（纯 JS 实现）替代原生 `bcrypt`，无需 C++ 编译环境。

**修改位置**: 文件顶部 imports 区域

**删除** (第 1-7 行):
```javascript
const express = require('express');
const http = require('http');
const { Server } = require('socket.io');
const path = require('path');
const fs = require('fs');
const crypto = require('crypto');
const initSqlJs = require('sql.js');
```

**替换为**:
```javascript
const express = require('express');
const http = require('http');
const { Server } = require('socket.io');
const path = require('path');
const fs = require('fs');
const crypto = require('crypto');
const bcrypt = require('bcrypt');
const initSqlJs = require('sql.js');
const config = require('./config');
const { initAuth, requireAuth } = require('./middleware/auth');
const { validateBody, validateQuery, schemas } = require('./middleware/validate');
```

---

**修改位置**: 第 13-16 行 (配置常量)

**删除**:
```javascript
const PORT = process.env.PORT || 3000;
const DB_PATH = path.join(__dirname, 'familymap.db');
const AMAP_KEY = process.env.AMAP_KEY || '';
```

**替换为** (使用 config 模块):
```javascript
const PORT = config.PORT;
const DB_PATH = config.DB_PATH;
const AMAP_KEY = config.AMAP_KEY;
```

---

**修改位置**: 第 170-178 行 (密码工具)

**删除**:
```javascript
// ==================== 密码工具 ====================
// 用SHA-256 + 固定盐值哈希密码（简单方案，无需bcrypt依赖）
const PWD_SALT = 'FamilyMap2026Salt';
function hashPassword(password) {
  return crypto.createHash('sha256').update(PWD_SALT + password).digest('hex');
}
function verifyPassword(password, hash) {
  return hashPassword(password) === hash;
}
```

**替换为**:
```javascript
// ==================== 密码工具 ====================
// bcrypt 安全哈希（cost factor 12，约 250ms/次）
const BCRYPT_ROUNDS = 12;
async function hashPassword(password) {
  return bcrypt.hash(password, BCRYPT_ROUNDS);
}
async function verifyPassword(password, hash) {
  return bcrypt.compare(password, hash);
}
```

**重要**: `hashPassword` 和 `verifyPassword` 现在是 **async** 函数，所有调用处需要加 `await`。

---

**修改位置**: 第 547-572 行 (注册路由)

**替换整个 app.post('/api/register')**:
```javascript
app.post('/api/register', validateBody(schemas.register), async (req, res) => {
  const { username, password, name } = req.body;

  const existing = queryOne('SELECT id FROM users WHERE username = ?', [username]);
  if (existing) return res.status(409).json({ error: '用户名已被占用' });

  const id = 'u_' + Date.now().toString(36) + Math.random().toString(36).substr(2, 5);
  const colors = ['#4F46E5','#EC4899','#10B981','#F59E0B','#EF4444','#8B5CF6','#06B6D4','#F97316'];
  const avatar_color = colors[Math.floor(Math.random() * colors.length)];
  const password_hash = await hashPassword(password);

  try {
    run('INSERT INTO users (id, name, avatar_color, username, password_hash) VALUES (?, ?, ?, ?, ?)',
      [id, name, avatar_color, username, password_hash]);
    run('INSERT INTO user_settings (user_id) VALUES (?)', [id]);
    const token = createSession(id, 'register');
    res.json({ id, name, avatar_color, username, token });
  } catch (e) {
    res.status(500).json({ error: '注册失败: ' + e.message });
  }
});
```

---

**修改位置**: 第 575-599 行 (登录路由)

**替换整个 app.post('/api/login')**:
```javascript
app.post('/api/login', validateBody(schemas.login), async (req, res) => {
  const { username, password, device_info } = req.body;

  const user = queryOne('SELECT * FROM users WHERE username = ?', [username]);
  if (!user) return res.status(401).json({ error: '用户名或密码错误' });

  if (!user.password_hash || !(await verifyPassword(password, user.password_hash))) {
    return res.status(401).json({ error: '用户名或密码错误' });
  }

  const token = createSession(user.id, device_info || '');

  res.json({
    id: user.id,
    name: user.name,
    avatar_color: user.avatar_color,
    username: user.username,
    mood: user.mood,
    is_sleeping: user.is_sleeping,
    ghost_mode: user.ghost_mode,
    token,
  });
});
```

---

### 修复 2: SQL 注入修复

**修改位置**: 第 719-724 行 (locations 路由)

**删除**:
```javascript
app.get('/api/users/:userId/locations', (req, res) => {
  const hours = parseInt(req.query.hours) || 24;
  const locations = queryAll(`SELECT * FROM locations
    WHERE user_id = ? AND recorded_at >= datetime('now', '-${hours} hours') ORDER BY recorded_at ASC`, [req.params.userId]);
  res.json(locations);
});
```

**替换为**:
```javascript
app.get('/api/users/:userId/locations', (req, res) => {
  const hours = Math.min(Math.max(parseInt(req.query.hours) || 24, 1), 720);
  const locations = queryAll(`SELECT * FROM locations
    WHERE user_id = ? AND recorded_at >= datetime('now', '-' || ? || ' hours') ORDER BY recorded_at ASC`,
    [req.params.userId, hours]);
  res.json(locations);
});
```

---

**修改位置**: 第 753-757 行 (stays 路由)

**删除**:
```javascript
app.get('/api/users/:userId/stays', (req, res) => {
  const days = parseInt(req.query.days) || 7;
  const stays = queryAll(`SELECT * FROM stays WHERE user_id = ? AND started_at >= datetime('now', '-${days} days') ORDER BY started_at DESC`, [req.params.userId]);
  res.json(stays);
});
```

**替换为**:
```javascript
app.get('/api/users/:userId/stays', (req, res) => {
  const days = Math.min(Math.max(parseInt(req.query.days) || 7, 1), 365);
  const stays = queryAll(`SELECT * FROM stays WHERE user_id = ? AND started_at >= datetime('now', '-' || ? || ' days') ORDER BY started_at DESC`,
    [req.params.userId, days]);
  res.json(stays);
});
```

---

**修改位置**: 第 1059-1064 行 (heatmap 路由)

**删除**:
```javascript
const rows = queryAll(
  `SELECT latitude, longitude FROM locations
   WHERE user_id = ? AND recorded_at >= datetime('now', '-${days} days')
     AND latitude IS NOT NULL AND longitude IS NOT NULL`,
  [req.params.userId]
);
```

**替换为**:
```javascript
const daysParam = Math.min(Math.max(parseInt(req.query.days) || 7, 1), 365);
const rows = queryAll(
  `SELECT latitude, longitude FROM locations
   WHERE user_id = ? AND recorded_at >= datetime('now', '-' || ? || ' days')
     AND latitude IS NOT NULL AND longitude IS NOT NULL`,
  [req.params.userId, daysParam]
);
```

---

**修改位置**: 第 1094-1098 行 (driving-score 路由)

**删除**:
```javascript
const rows = queryAll(
  `SELECT speed, recorded_at FROM locations
   WHERE user_id = ? AND speed > 0 AND recorded_at >= datetime('now', '-${days} days')
   ORDER BY recorded_at ASC`,
  [req.params.userId]
);
```

**替换为**:
```javascript
const daysParam = Math.min(Math.max(parseInt(req.query.days) || 7, 1), 365);
const rows = queryAll(
  `SELECT speed, recorded_at FROM locations
   WHERE user_id = ? AND speed > 0 AND recorded_at >= datetime('now', '-' || ? || ' days')
   ORDER BY recorded_at ASC`,
  [req.params.userId, daysParam]
);
```

---

### 修复 3: 添加 API 认证中间件

在 `initDB()` 完成后、`server.listen()` 之前，添加认证初始化：

**修改位置**: 第 1618-1626 行 (启动代码)

**替换为**:
```javascript
initDB().then(() => {
  // 初始化认证模块
  initAuth(queryOne);
  cleanExpiredSessions();

  // === 需要认证的 API 路由 ===
  // 用户信息
  app.get('/api/users/:userId', requireAuth, (req, res) => {
    const user = queryOne('SELECT * FROM users WHERE id = ?', [req.params.userId]);
    if (!user) return res.status(404).json({ error: '用户不存在' });
    delete user.password_hash;
    res.json(user);
  });

  app.put('/api/users/:userId', requireAuth, (req, res) => {
    const fields = [];
    const values = [];
    ['name', 'avatar_color', 'mood', 'is_sleeping', 'ghost_mode'].forEach(f => {
      if (req.body[f] !== undefined) { fields.push(`${f} = ?`); values.push(req.body[f]); }
    });
    if (fields.length === 0) return res.json({ ok: true });
    values.push(req.params.userId);
    run(`UPDATE users SET ${fields.join(', ')} WHERE id = ?`, values);
    res.json({ ok: true });
  });

  // 圈子
  app.post('/api/circles', requireAuth, validateBody(schemas.createCircle), (req, res) => {
    const { name, userId } = req.body;
    const id = 'c_' + Date.now().toString(36) + Math.random().toString(36).substr(2, 5);
    const invite_code = Math.random().toString(36).substr(2, 6).toUpperCase();
    run('INSERT INTO circles (id, name, invite_code) VALUES (?, ?, ?)', [id, name, invite_code]);
    run('INSERT INTO circle_members (circle_id, user_id) VALUES (?, ?)', [id, userId]);
    res.json({ id, name, invite_code });
  });

  app.post('/api/circles/join', requireAuth, validateBody(schemas.joinCircle), (req, res) => {
    const { inviteCode, userId } = req.body;
    const circle = queryOne('SELECT * FROM circles WHERE invite_code = ?', [inviteCode]);
    if (!circle) return res.status(404).json({ error: '邀请码无效' });
    const existing = queryOne('SELECT * FROM circle_members WHERE circle_id = ? AND user_id = ?', [circle.id, userId]);
    if (existing) return res.json({ circle, alreadyMember: true });
    run('INSERT INTO circle_members (circle_id, user_id) VALUES (?, ?)', [circle.id, userId]);
    const userName = queryOne('SELECT name FROM users WHERE id = ?', [userId])?.name || '新成员';
    io.to(circle.id).emit('circle:join', { circleId: circle.id, userId, userName, timestamp: Date.now() });
    res.json({ circle, alreadyMember: false });
  });

  // 围栏
  app.post('/api/circles/:circleId/geofences', requireAuth, validateBody(schemas.createGeofence), (req, res) => {
    const { name, latitude, longitude, radius, createdBy } = req.body;
    run('INSERT INTO geofences (circle_id, name, latitude, longitude, radius, created_by) VALUES (?, ?, ?, ?, ?, ?)',
      [req.params.circleId, name, latitude, longitude, radius || 200, createdBy]);
    const row = queryOne('SELECT last_insert_rowid() as id');
    res.json({ id: row.id, name, latitude, longitude, radius: radius || 200 });
  });

  app.delete('/api/geofences/:id', requireAuth, (req, res) => {
    run('DELETE FROM geofences WHERE id = ?', [req.params.id]);
    res.json({ ok: true });
  });

  // 聊天消息
  app.post('/api/circles/:circleId/messages', requireAuth, validateBody(schemas.sendMessage), (req, res) => {
    const { userId, type, content } = req.body;
    run('INSERT INTO messages (circle_id, user_id, type, content) VALUES (?, ?, ?, ?)',
      [req.params.circleId, userId, type || 'text', content]);
    const row = queryOne('SELECT last_insert_rowid() as id');
    const user = queryOne('SELECT name, avatar_color FROM users WHERE id = ?', [userId]);
    const msg = { id: row.id, circle_id: req.params.circleId, user_id: userId, type: type || 'text', content,
      name: user?.name, avatar_color: user?.avatar_color, created_at: new Date().toISOString() };
    io.to(req.params.circleId).emit('chat:message', msg);
    res.json(msg);
  });

  // SOS
  app.post('/api/sos', requireAuth, validateBody(schemas.sendSos), async (req, res) => {
    const { userId, latitude, longitude } = req.body;
    const geoResult = await reverseGeocode(latitude, longitude);
    run('INSERT INTO sos_alerts (user_id, latitude, longitude, address) VALUES (?, ?, ?, ?)',
      [userId, latitude, longitude, geoResult.address]);
    const user = queryOne('SELECT name FROM users WHERE id = ?', [userId]);
    const circles = queryAll('SELECT circle_id FROM circle_members WHERE user_id = ?', [userId]);
    circles.forEach(c => {
      io.to(c.circle_id).emit('sos:alert', {
        userId, userName: user?.name || '未知',
        latitude, longitude, address: geoResult.address,
        timestamp: Date.now()
      });
    });
    res.json({ ok: true, address: geoResult.address });
  });

  app.put('/api/sos/:id/resolve', requireAuth, (req, res) => {
    run('UPDATE sos_alerts SET status = ? WHERE id = ?', ['resolved', req.params.id]);
    res.json({ ok: true });
  });

  // 足迹
  app.post('/api/users/:userId/footprints', requireAuth, validateBody(schemas.createFootprint), (req, res) => {
    const { name, latitude, longitude, category } = req.body;
    run('INSERT INTO footprints (user_id, name, latitude, longitude, category) VALUES (?, ?, ?, ?, ?)',
      [req.params.userId, name, latitude, longitude, category || 'other']);
    const row = queryOne('SELECT last_insert_rowid() as id');
    res.json({ id: row.id, name, latitude, longitude });
  });

  app.delete('/api/footprints/:id', requireAuth, (req, res) => {
    run('DELETE FROM footprints WHERE id = ?', [req.params.id]);
    res.json({ ok: true });
  });

  // 用户设置
  app.put('/api/users/:userId/settings', requireAuth, (req, res) => {
    const fields = []; const values = [];
    ['blur_location', 'share_paused', 'trail_skin', 'nickname_color', 'dark_mode', 'lang'].forEach(f => {
      if (req.body[f] !== undefined) { fields.push(`${f} = ?`); values.push(req.body[f]); }
    });
    if (fields.length > 0) { values.push(req.params.userId); run(`UPDATE user_settings SET ${fields.join(', ')} WHERE user_id = ?`, values); }
    res.json({ ok: true });
  });

  // 联系人
  app.post('/api/contacts', requireAuth, (req, res) => {
    const { userId, contactId, type } = req.body;
    if (!userId || !contactId) return res.status(400).json({ error: '参数不完整' });
    const existing = queryOne('SELECT * FROM contacts WHERE user_id = ? AND contact_id = ?', [userId, contactId]);
    if (existing) return res.json({ ok: true, already: true });
    run('INSERT INTO contacts (user_id, contact_id, type) VALUES (?, ?, ?)', [userId, contactId, type || 'friend']);
    res.json({ ok: true });
  });

  app.delete('/api/contacts/:userId/:contactId', requireAuth, (req, res) => {
    run('DELETE FROM contacts WHERE user_id = ? AND contact_id = ?', [req.params.userId, req.params.contactId]);
    res.json({ ok: true });
  });

  // 紧急联系人
  app.post('/api/users/:userId/emergency-contacts', requireAuth, validateBody(schemas.createEmergencyContact), (req, res) => {
    const { name, phone, relation } = req.body;
    run('INSERT INTO emergency_contacts (user_id, name, phone, relation) VALUES (?, ?, ?, ?)',
      [req.params.userId, name, phone, relation || 'family']);
    res.json({ ok: true });
  });

  app.delete('/api/emergency-contacts/:id', requireAuth, (req, res) => {
    run('DELETE FROM emergency_contacts WHERE id = ?', [req.params.id]);
    res.json({ ok: true });
  });

  // 分享链接
  app.post('/api/share-link', requireAuth, validateBody(schemas.shareLink), (req, res) => {
    const { userId, latitude, longitude, durationMinutes, trackMode } = req.body;
    const token = crypto.randomBytes(8).toString('hex');
    const expires = Date.now() + (durationMinutes || config.SHARE_DEFAULT_DURATION_MINUTES) * 60000;
    _shareTokens.set(token, { userId, latitude, longitude, expires, trackMode: !!trackMode });
    for (const [k, v] of _shareTokens) { if (v.expires < Date.now()) _shareTokens.delete(k); }
    res.json({ token, url: `http://www.zhp0104.fun:${PORT}/share/${token}`, expiresAt: new Date(expires).toISOString() });
  });

  // 管理接口（需要管理员权限或内网访问）
  app.post('/api/admin/refresh-geocode-cache', requireAuth, async (req, res) => {
    // ... 保持原有逻辑不变 ...
  });

  server.listen(PORT, config.HOST, () => {
    console.log(`\n  FamilyMap 位置共享服务已启动`);
    console.log(`  本地访问: http://localhost:${PORT}`);
    console.log(`  局域网: http://<IP>:${PORT}`);
    console.log(`  逆地理解码: ${AMAP_KEY ? '已配置高德Key' : '未配置(使用坐标降级)'}\n`);
  });
}).catch(err => { console.error('DB初始化失败:', err); process.exit(1); });
```

---

### 修复 4: 服务器地址配置化 (Flutter)

**修改文件**: `lib/services/socket_service.dart`

**删除** (约第 35 行):
```dart
final String serverUrl = 'http://www.zhp0104.fun:8090';
```

**替换为**:
```dart
static const String serverUrl = String.fromEnvironment(
  'SERVER_URL',
  defaultValue: 'http://www.zhp0104.fun:8090',
);
```

**修改文件**: `lib/services/api_service.dart`

找到所有硬编码的服务器地址，替换为环境变量配置：
```dart
static const String baseUrl = String.fromEnvironment(
  'SERVER_URL',
  defaultValue: 'http://www.zhp0104.fun:8090',
);
```

---

## 安装步骤

```bash
# 1. 进入项目目录
cd FamilyMap

# 2. 安装新依赖
npm install

# 3. 如果已有旧数据库，密码需要重新注册
#    （因为 bcrypt 和 SHA-256 不兼容）
rm familymap.db

# 4. 启动服务
PORT=8090 AMAP_KEY=你的Key node server.js
```

## ⚠️ 关键注意事项

### 1. 密码迁移

bcrypt 和 SHA-256 不兼容。升级后有两种方案：

**方案 A（推荐）: 自动检测旧密码并迁移**

在登录路由中添加自动迁移逻辑：

```javascript
app.post('/api/login', validateBody(schemas.login), async (req, res) => {
  const { username, password, device_info } = req.body;
  const user = queryOne('SELECT * FROM users WHERE username = ?', [username]);
  if (!user) return res.status(401).json({ error: '用户名或密码错误' });

  // 先尝试 bcrypt 验证
  let passwordValid = false;
  if (user.password_hash && user.password_hash.startsWith('$2b$')) {
    // 新格式 (bcrypt)
    passwordValid = await bcrypt.compare(password, user.password_hash);
  } else if (user.password_hash) {
    // 旧格式 (SHA-256)，验证后自动迁移
    const crypto = require('crypto');
    const oldHash = crypto.createHash('sha256').update('FamilyMap2026Salt' + password).digest('hex');
    if (oldHash === user.password_hash) {
      passwordValid = true;
      // 自动迁移到 bcrypt
      const newHash = await bcrypt.hash(password, 12);
      run('UPDATE users SET password_hash = ? WHERE id = ?', [newHash, user.id]);
      console.log(`[迁移] 用户 ${user.id} 密码已自动迁移到 bcrypt`);
    }
  }

  if (!passwordValid) {
    return res.status(401).json({ error: '用户名或密码错误' });
  }

  const token = createSession(user.id, device_info || '');
  // ... 返回用户信息
});
```

**方案 B: 简单方案（要求用户重新注册）**

升级后直接删除数据库，所有用户重新注册。

### 2. Express 路由顺序（重要！）

Express 按注册顺序匹配路由。**必须先删除原始路由定义，再添加带认证的新路由**。

需要**删除**的原始路由（在 server.js 中）：

| 路由 | 行号范围 | 操作 |
|------|----------|------|
| `GET /api/users/:userId` | ~622-628 | 删除，用 requireAuth 版本替代 |
| `PUT /api/users/:userId` | ~639-649 | 删除，用 requireAuth 版本替代 |
| `POST /api/circles` | ~652-660 | 删除，用 requireAuth 版本替代 |
| `POST /api/circles/join` | ~662-678 | 删除，用 requireAuth 版本替代 |
| `POST /api/circles/:circleId/geofences` | ~739-745 | 删除，用 requireAuth 版本替代 |
| `DELETE /api/geofences/:id` | ~747-750 | 删除，用 requireAuth 版本替代 |
| `POST /api/circles/:circleId/messages` | ~821-831 | 删除，用 requireAuth 版本替代 |
| `POST /api/sos` | ~784-801 | 删除，用 requireAuth 版本替代 |
| `PUT /api/sos/:id/resolve` | ~803-806 | 删除，用 requireAuth 版本替代 |
| `POST /api/users/:userId/footprints` | ~838-844 | 删除，用 requireAuth 版本替代 |
| `DELETE /api/footprints/:id` | ~846-849 | 删除，用 requireAuth 版本替代 |
| `PUT /api/users/:userId/settings` | ~858-865 | 删除，用 requireAuth 版本替代 |
| `POST /api/contacts` | ~886-892 | 删除，用 requireAuth 版本替代 |
| `DELETE /api/contacts/:userId/:contactId` | ~894-897 | 删除，用 requireAuth 版本替代 |
| `POST /api/users/:userId/emergency-contacts` | ~1015-1021 | 删除，用 requireAuth 版本替代 |
| `DELETE /api/emergency-contacts/:id` | ~1023-1026 | 删除，用 requireAuth 版本替代 |
| `POST /api/share-link` | ~916-925 | 删除，用 requireAuth 版本替代 |
| `POST /api/admin/refresh-geocode-cache` | ~1163-1201 | 删除，用 requireAuth 版本替代 |

**不需要认证的路由（保留原样）：**
- `POST /api/register` — 注册
- `POST /api/login` — 登录
- `POST /api/users` — 旧版注册（兼容）
- `POST /api/logout` — 登出
- `GET /api/users/:userId/circles` — 查询圈子列表
- `GET /api/circles/:circleId/members` — 查询圈子成员
- `GET /api/circles/:circleId/messages` — 查询聊天消息
- `GET /api/circles/:circleId/geofences` — 查询围栏
- `GET /api/users/:userId/stays` — 查询停留
- `GET /api/users/:userId/locations` — 查询位置历史
- `GET /api/users/:userId/timeline` — 查询时间线
- `GET /api/users/:userId/track` — 查询轨迹
- `GET /api/users/:userId/heatmap` — 热力图
- `GET /api/users/:userId/driving-score` — 驾驶评分
- `GET /api/users/:userId/world` — 世界地图
- `GET /api/users/:userId/contacts` — 联系人列表
- `GET /api/users/:userId/emergency-contacts` — 紧急联系人列表
- `GET /api/users/:userId/footprints` — 足迹列表
- `GET /api/users/:userId/settings` — 用户设置
- `GET /api/geocode` — 逆地理解码
- `GET /api/eta` — ETA 预估
- `GET /share/:token` — 分享页面
- `GET /api/share/:token` — 分享数据
- `GET /api/admin/geocode-stats` — 缓存统计
- `GET /api/users/:userId/export/gpx` — GPX 导出

### 3. Token 传递

客户端请求需要在 HTTP Header 中添加：
```
Authorization: Bearer <token>
```

Flutter 中使用 `http` 包时：
```dart
final response = await http.get(
  Uri.parse('$baseUrl/api/users/$userId'),
  headers: {'Authorization': 'Bearer $token'},
);
```

### 4. 环境变量

生产环境务必：
- 设置 `PWD_SALT` 为随机强密码（不是默认值）
- 设置 `AMAP_KEY` 为高德 API Key
- 使用 HTTPS（nginx 反向代理）
