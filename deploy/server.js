const express = require('express');
const http = require('http');
const { Server } = require('socket.io');
const path = require('path');
const fs = require('fs');
const initSqlJs = require('sql.js');

const app = express();
const server = http.createServer(app);
const io = new Server(server);

const PORT = process.env.PORT || 3000;
const DB_PATH = path.join(__dirname, 'familymap.db');
const AMAP_KEY = process.env.AMAP_KEY || ''; // 高德API Key，环境变量配置

// ==================== 数据库 ====================
let db;
let saveTimeout;

async function initDB() {
  const SQL = await initSqlJs();
  if (fs.existsSync(DB_PATH)) {
    const buf = fs.readFileSync(DB_PATH);
    db = new SQL.Database(buf);
  } else {
    db = new SQL.Database();
  }

  db.run(`CREATE TABLE IF NOT EXISTS users (
    id TEXT PRIMARY KEY, name TEXT NOT NULL, avatar_color TEXT DEFAULT '#4F46E5',
    mood TEXT DEFAULT '', is_sleeping INTEGER DEFAULT 0, ghost_mode TEXT DEFAULT 'off',
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP)`);
  db.run(`CREATE TABLE IF NOT EXISTS circles (
    id TEXT PRIMARY KEY, name TEXT NOT NULL, invite_code TEXT UNIQUE NOT NULL,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP)`);
  db.run(`CREATE TABLE IF NOT EXISTS circle_members (
    circle_id TEXT NOT NULL, user_id TEXT NOT NULL,
    joined_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (circle_id, user_id))`);
  db.run(`CREATE TABLE IF NOT EXISTS locations (
    id INTEGER PRIMARY KEY AUTOINCREMENT, user_id TEXT NOT NULL,
    latitude REAL NOT NULL, longitude REAL NOT NULL, accuracy REAL,
    battery_level INTEGER, is_charging INTEGER DEFAULT 0, speed REAL DEFAULT 0,
    address TEXT, recorded_at DATETIME DEFAULT CURRENT_TIMESTAMP)`);
  db.run(`CREATE TABLE IF NOT EXISTS geofences (
    id INTEGER PRIMARY KEY AUTOINCREMENT, circle_id TEXT NOT NULL,
    name TEXT NOT NULL, latitude REAL NOT NULL, longitude REAL NOT NULL,
    radius INTEGER DEFAULT 200, created_by TEXT NOT NULL,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP)`);
  db.run(`CREATE TABLE IF NOT EXISTS stays (
    id INTEGER PRIMARY KEY AUTOINCREMENT, user_id TEXT NOT NULL,
    latitude REAL NOT NULL, longitude REAL NOT NULL, address TEXT,
    started_at DATETIME NOT NULL, ended_at DATETIME,
    duration_minutes INTEGER)`);
  db.run(`CREATE TABLE IF NOT EXISTS messages (
    id INTEGER PRIMARY KEY AUTOINCREMENT, circle_id TEXT NOT NULL,
    user_id TEXT NOT NULL, type TEXT DEFAULT 'text', content TEXT NOT NULL,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP)`);
  db.run(`CREATE TABLE IF NOT EXISTS sos_alerts (
    id INTEGER PRIMARY KEY AUTOINCREMENT, user_id TEXT NOT NULL,
    latitude REAL NOT NULL, longitude REAL NOT NULL, address TEXT,
    status TEXT DEFAULT 'active', created_at DATETIME DEFAULT CURRENT_TIMESTAMP)`);
  db.run(`CREATE TABLE IF NOT EXISTS contacts (
    id INTEGER PRIMARY KEY AUTOINCREMENT, user_id TEXT NOT NULL,
    contact_id TEXT NOT NULL, type TEXT DEFAULT 'friend',
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (user_id, contact_id))`);
  db.run(`CREATE TABLE IF NOT EXISTS footprints (
    id INTEGER PRIMARY KEY AUTOINCREMENT, user_id TEXT NOT NULL,
    name TEXT NOT NULL, latitude REAL NOT NULL, longitude REAL NOT NULL,
    category TEXT DEFAULT 'other', created_at DATETIME DEFAULT CURRENT_TIMESTAMP)`);
  db.run(`CREATE TABLE IF NOT EXISTS geocode_cache (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    lat_key TEXT NOT NULL, lng_key TEXT NOT NULL,
    address TEXT NOT NULL, formatted TEXT,
    cached_at DATETIME DEFAULT CURRENT_TIMESTAMP)`);
  db.run(`CREATE TABLE IF NOT EXISTS user_settings (
    user_id TEXT PRIMARY KEY,
    blur_location INTEGER DEFAULT 0,
    share_paused INTEGER DEFAULT 0,
    trail_skin TEXT DEFAULT 'default',
    nickname_color TEXT DEFAULT '',
    dark_mode INTEGER DEFAULT 0,
    lang TEXT DEFAULT 'zh')`);

  db.run('CREATE INDEX IF NOT EXISTS idx_loc_user_time ON locations(user_id, recorded_at DESC)');
  db.run('CREATE INDEX IF NOT EXISTS idx_msg_circle_time ON messages(circle_id, created_at ASC)');
  db.run('CREATE INDEX IF NOT EXISTS idx_stay_user ON stays(user_id, started_at DESC)');
  db.run('CREATE INDEX IF NOT EXISTS idx_geocode ON geocode_cache(lat_key, lng_key)');

  saveDB();
}

function saveDB() {
  clearTimeout(saveTimeout);
  saveTimeout = setTimeout(() => {
    try { fs.writeFileSync(DB_PATH, Buffer.from(db.export())); }
    catch (e) { console.error('DB save fail:', e.message); }
  }, 2000);
}

function queryAll(sql, params = []) {
  const stmt = db.prepare(sql); stmt.bind(params);
  const rows = [];
  while (stmt.step()) rows.push(stmt.getAsObject());
  stmt.free(); return rows;
}
function queryOne(sql, params = []) {
  const rows = queryAll(sql, params);
  return rows.length > 0 ? rows[0] : null;
}
function run(sql, params = []) { db.run(sql, params); saveDB(); }

// ==================== 逆地理解码 ====================
const https = require('https');

async function reverseGeocode(lat, lng) {
  // 1. 查缓存（精度到小数点后3位，约100米）
  const latKey = lat.toFixed(3);
  const lngKey = lng.toFixed(3);
  const cached = queryOne('SELECT * FROM geocode_cache WHERE lat_key = ? AND lng_key = ?', [latKey, lngKey]);
  if (cached) return { address: cached.address, formatted: cached.formatted };

  // 2. 无缓存，尝试调用高德API
  if (!AMAP_KEY) {
    const fallback = `${lat.toFixed(4)}, ${lng.toFixed(4)}`;
    return { address: fallback, formatted: fallback };
  }

  return new Promise((resolve) => {
    const url = `https://restapi.amap.com/v3/geocode/regeo?key=${AMAP_KEY}&location=${lng},${lat}&extensions=base`;
    https.get(url, (res) => {
      let data = '';
      res.on('data', chunk => data += chunk);
      res.on('end', () => {
        try {
          const json = JSON.parse(data);
          const address = json.regeocode?.formatted_address || `${lat.toFixed(4)}, ${lng.toFixed(4)}`;
          const formatted = json.regeocode?.addressComponent?.township ||
            json.regeocode?.addressComponent?.street ||
            address.split('区').pop()?.substring(0, 20) || address;
          // 存缓存
          run('INSERT INTO geocode_cache (lat_key, lng_key, address, formatted) VALUES (?, ?, ?, ?)',
            [latKey, lngKey, address, formatted]);
          resolve({ address, formatted });
        } catch (e) {
          resolve({ address: `${lat.toFixed(4)}, ${lng.toFixed(4)}`, formatted: '' });
        }
      });
    }).on('error', () => {
      resolve({ address: `${lat.toFixed(4)}, ${lng.toFixed(4)}`, formatted: '' });
    });
  });
}

// ==================== 停留计算 ====================
function updateStay(userId, lat, lng, address) {
  // 查最近未结束的停留
  const active = queryOne('SELECT * FROM stays WHERE user_id = ? AND ended_at IS NULL ORDER BY started_at DESC LIMIT 1', [userId]);

  if (active) {
    const dist = getDistance(lat, lng, active.latitude, active.longitude);
    if (dist < 100) {
      // 还在同一地点，不操作
      return;
    } else {
      // 离开了，结束当前停留
      const started = new Date(active.started_at);
      const ended = new Date();
      const dur = Math.round((ended - started) / 60000);
      run('UPDATE stays SET ended_at = datetime("now"), duration_minutes = ? WHERE id = ?', [dur, active.id]);

      // 广播离开通知
      const user = queryOne('SELECT name FROM users WHERE id = ?', [userId]);
      const info = [...onlineUsers.values()].find(i => i.userId === userId);
      if (info) {
        info.circleIds.forEach(cid => {
          io.to(cid).emit('trip:report', {
            userId, userName: user?.name || '未知',
            action: 'left', address: active.address || '某地',
            duration: dur, timestamp: Date.now()
          });
        });
      }
    }
  }

  // 查最近30分钟内是否有同位置的已结束停留（避免频繁创建）
  const recent = queryOne(
    `SELECT * FROM stays WHERE user_id = ? AND ended_at IS NOT NULL AND ended_at >= datetime("now", "-30 minutes") AND latitude = ? AND longitude = ? ORDER BY ended_at DESC LIMIT 1`,
    [userId, lat, lng]
  );

  if (!recent) {
    // 创建新停留
    run('INSERT INTO stays (user_id, latitude, longitude, address, started_at) VALUES (?, ?, ?, ?, datetime("now"))',
      [userId, lat, lng, address || '']);
  } else {
    // 回到最近离开的地方，重新开启停留
    run('INSERT INTO stays (user_id, latitude, longitude, address, started_at) VALUES (?, ?, ?, ?, datetime("now"))',
      [userId, recent.latitude, recent.longitude, recent.address || '']);
  }
}

// ==================== 存活检测 ====================
function checkAlive() {
  const users = queryAll('SELECT id, name FROM users');
  users.forEach(u => {
    const lastLoc = queryOne('SELECT recorded_at FROM locations WHERE user_id = ? ORDER BY recorded_at DESC LIMIT 1', [u.id]);
    if (!lastLoc) return;
    const lastTime = new Date(lastLoc.recorded_at);
    const hoursSince = (Date.now() - lastTime.getTime()) / 3600000;

    if (hoursSince >= 24) {
      // 超过24小时无位置更新，通知守护人
      const circles = queryAll('SELECT circle_id FROM circle_members WHERE user_id = ?', [u.id]);
      circles.forEach(c => {
        io.to(c.circle_id).emit('alive:warning', {
          userId: u.id, userName: u.name,
          hours: Math.round(hoursSince),
          lastLocation: lastLoc.recorded_at,
          timestamp: Date.now()
        });
      });
    }
  });
}

// 每小时检查一次
setInterval(checkAlive, 3600000);

// ==================== 静态文件和JSON ====================
app.use(express.static(path.join(__dirname, 'public')));
app.use(express.json({ limit: '10mb' }));

// ==================== API 路由 ====================

// --- 用户 ---
app.post('/api/users', (req, res) => {
  const { name } = req.body;
  if (!name) return res.status(400).json({ error: '名字不能为空' });
  const id = 'u_' + Date.now().toString(36) + Math.random().toString(36).substr(2, 5);
  const colors = ['#4F46E5','#EC4899','#10B981','#F59E0B','#EF4444','#8B5CF6','#06B6D4','#F97316'];
  const avatar_color = colors[Math.floor(Math.random() * colors.length)];
  run('INSERT INTO users (id, name, avatar_color) VALUES (?, ?, ?)', [id, name, avatar_color]);
  run('INSERT INTO user_settings (user_id) VALUES (?)', [id]);
  res.json({ id, name, avatar_color });
});

app.get('/api/users/:userId', (req, res) => {
  const user = queryOne('SELECT * FROM users WHERE id = ?', [req.params.userId]);
  if (!user) return res.status(404).json({ error: '用户不存在' });
  res.json(user);
});

app.put('/api/users/:userId', (req, res) => {
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

// --- 圈子 ---
app.post('/api/circles', (req, res) => {
  const { name, userId } = req.body;
  if (!name || !userId) return res.status(400).json({ error: '参数不完整' });
  const id = 'c_' + Date.now().toString(36) + Math.random().toString(36).substr(2, 5);
  const invite_code = Math.random().toString(36).substr(2, 6).toUpperCase();
  run('INSERT INTO circles (id, name, invite_code) VALUES (?, ?, ?)', [id, name, invite_code]);
  run('INSERT INTO circle_members (circle_id, user_id) VALUES (?, ?)', [id, userId]);
  res.json({ id, name, invite_code });
});

app.post('/api/circles/join', (req, res) => {
  const { inviteCode, userId } = req.body;
  if (!inviteCode || !userId) return res.status(400).json({ error: '参数不完整' });
  const circle = queryOne('SELECT * FROM circles WHERE invite_code = ?', [inviteCode]);
  if (!circle) return res.status(404).json({ error: '邀请码无效' });
  const existing = queryOne('SELECT * FROM circle_members WHERE circle_id = ? AND user_id = ?', [circle.id, userId]);
  if (existing) return res.json({ circle, alreadyMember: true });
  run('INSERT INTO circle_members (circle_id, user_id) VALUES (?, ?)', [circle.id, userId]);
  res.json({ circle, alreadyMember: false });
});

app.get('/api/users/:userId/circles', (req, res) => {
  const circles = queryAll(`SELECT c.*, (SELECT COUNT(*) FROM circle_members WHERE circle_id = c.id) as member_count
    FROM circles c JOIN circle_members cm ON c.id = cm.circle_id WHERE cm.user_id = ?`, [req.params.userId]);
  res.json(circles);
});

app.get('/api/circles/:circleId/members', (req, res) => {
  const members = queryAll(`SELECT u.id, u.name, u.avatar_color, u.mood, u.is_sleeping, u.ghost_mode,
    l.latitude, l.longitude, l.accuracy, l.battery_level, l.is_charging, l.speed, l.address, l.recorded_at
    FROM users u JOIN circle_members cm ON u.id = cm.user_id
    LEFT JOIN locations l ON u.id = l.user_id WHERE cm.circle_id = ?`, [req.params.circleId]);
  const latest = {};
  members.forEach(m => {
    if (!latest[m.id] || (m.recorded_at && (!latest[m.id].recorded_at || m.recorded_at > latest[m.id].recorded_at))) {
      latest[m.id] = m;
    }
  });
  // 为每个成员添加当前停留信息
  Object.values(latest).forEach(m => {
    const stay = queryOne('SELECT * FROM stays WHERE user_id = ? AND ended_at IS NULL ORDER BY started_at DESC LIMIT 1', [m.id]);
    if (stay) {
      const mins = Math.round((Date.now() - new Date(stay.started_at).getTime()) / 60000);
      m.stay_address = stay.address;
      m.stay_minutes = mins;
    }
  });
  res.json(Object.values(latest));
});

// --- 位置 ---
app.get('/api/users/:userId/locations', (req, res) => {
  const hours = parseInt(req.query.hours) || 24;
  const locations = queryAll(`SELECT * FROM locations
    WHERE user_id = ? AND recorded_at >= datetime('now', '-${hours} hours') ORDER BY recorded_at ASC`, [req.params.userId]);
  res.json(locations);
});

// 逆地理解码
app.get('/api/geocode', async (req, res) => {
  const { lat, lng } = req.query;
  if (!lat || !lng) return res.status(400).json({ error: '参数不完整' });
  const result = await reverseGeocode(parseFloat(lat), parseFloat(lng));
  res.json(result);
});

// --- 围栏 ---
app.get('/api/circles/:circleId/geofences', (req, res) => {
  res.json(queryAll('SELECT * FROM geofences WHERE circle_id = ?', [req.params.circleId]));
});

app.post('/api/circles/:circleId/geofences', (req, res) => {
  const { name, latitude, longitude, radius, createdBy } = req.body;
  run('INSERT INTO geofences (circle_id, name, latitude, longitude, radius, created_by) VALUES (?, ?, ?, ?, ?, ?)',
    [req.params.circleId, name, latitude, longitude, radius || 200, createdBy]);
  const row = queryOne('SELECT last_insert_rowid() as id');
  res.json({ id: row.id, name, latitude, longitude, radius: radius || 200 });
});

app.delete('/api/geofences/:id', (req, res) => {
  run('DELETE FROM geofences WHERE id = ?', [req.params.id]);
  res.json({ ok: true });
});

// --- 停留记录 ---
app.get('/api/users/:userId/stays', (req, res) => {
  const days = parseInt(req.query.days) || 7;
  const stays = queryAll(`SELECT * FROM stays WHERE user_id = ? AND started_at >= datetime('now', '-${days} days') ORDER BY started_at DESC`, [req.params.userId]);
  res.json(stays);
});

// --- 行程时间线（某天的所有停留+移动） ---
app.get('/api/users/:userId/timeline', (req, res) => {
  const date = req.query.date || new Date().toISOString().split('T')[0];
  const stays = queryAll(`SELECT * FROM stays WHERE user_id = ? AND date(started_at) = ? ORDER BY started_at ASC`, [req.params.userId, date]);
  res.json(stays);
});

// --- SOS ---
app.post('/api/sos', async (req, res) => {
  const { userId, latitude, longitude } = req.body;
  const geoResult = await reverseGeocode(latitude, longitude);
  run('INSERT INTO sos_alerts (user_id, latitude, longitude, address) VALUES (?, ?, ?, ?)',
    [userId, latitude, longitude, geoResult.address]);
  const user = queryOne('SELECT name FROM users WHERE id = ?', [userId]);

  // 通知所有圈子
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

app.put('/api/sos/:id/resolve', (req, res) => {
  run('UPDATE sos_alerts SET status = ? WHERE id = ?', ['resolved', req.params.id]);
  res.json({ ok: true });
});

// --- 聊天消息 ---
app.get('/api/circles/:circleId/messages', (req, res) => {
  const limit = parseInt(req.query.limit) || 50;
  const before = req.query.before; // cursor for pagination
  let sql = 'SELECT m.*, u.name, u.avatar_color FROM messages m JOIN users u ON m.user_id = u.id WHERE m.circle_id = ?';
  const params = [req.params.circleId];
  if (before) { sql += ' AND m.id < ?'; params.push(before); }
  sql += ' ORDER BY m.created_at DESC LIMIT ?';
  params.push(limit);
  const msgs = queryAll(sql, params).reverse();
  res.json(msgs);
});

app.post('/api/circles/:circleId/messages', (req, res) => {
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

// --- 足迹 ---
app.get('/api/users/:userId/footprints', (req, res) => {
  res.json(queryAll('SELECT * FROM footprints WHERE user_id = ? ORDER BY created_at DESC', [req.params.userId]));
});

app.post('/api/users/:userId/footprints', (req, res) => {
  const { name, latitude, longitude, category } = req.body;
  run('INSERT INTO footprints (user_id, name, latitude, longitude, category) VALUES (?, ?, ?, ?, ?)',
    [req.params.userId, name, latitude, longitude, category || 'other']);
  const row = queryOne('SELECT last_insert_rowid() as id');
  res.json({ id: row.id, name, latitude, longitude });
});

app.delete('/api/footprints/:id', (req, res) => {
  run('DELETE FROM footprints WHERE id = ?', [req.params.id]);
  res.json({ ok: true });
});

// --- 用户设置 ---
app.get('/api/users/:userId/settings', (req, res) => {
  let s = queryOne('SELECT * FROM user_settings WHERE user_id = ?', [req.params.userId]);
  if (!s) { run('INSERT INTO user_settings (user_id) VALUES (?)', [req.params.userId]); s = { user_id: req.params.userId }; }
  res.json(s);
});

app.put('/api/users/:userId/settings', (req, res) => {
  const fields = []; const values = [];
  ['blur_location', 'share_paused', 'trail_skin', 'nickname_color', 'dark_mode', 'lang'].forEach(f => {
    if (req.body[f] !== undefined) { fields.push(`${f} = ?`); values.push(req.body[f]); }
  });
  if (fields.length > 0) { values.push(req.params.userId); run(`UPDATE user_settings SET ${fields.join(', ')} WHERE user_id = ?`, values); }
  res.json({ ok: true });
});

// --- 世界迷雾（统计去过的城市/国家） ---
app.get('/api/users/:userId/world', (req, res) => {
  const locations = queryAll('SELECT DISTINCT ROUND(latitude, 1) as lat_key, ROUND(longitude, 1) as lng_key FROM locations WHERE user_id = ?', [req.params.userId]);
  const total = queryOne('SELECT COUNT(DISTINCT ROUND(latitude, 1).toString() || "," || ROUND(longitude, 1).toString()) as grid_count FROM locations WHERE user_id = ?', [req.params.userId]);
  const cities = new Set();
  locations.forEach(l => {
    const addr = queryOne('SELECT address FROM geocode_cache WHERE lat_key = ? AND lng_key = ?', [l.lat_key.toFixed(3), l.lng_key.toFixed(3)]);
    if (addr?.address) {
      const match = addr.address.match(/市([^区县市]+[区县市])/);
      if (match) cities.add(match[1]);
    }
  });
  res.json({ gridCount: locations.length, cities: [...cities], cityCount: cities.size });
});

// --- 联系人/好友 ---
app.post('/api/contacts', (req, res) => {
  const { userId, contactId, type } = req.body;
  const existing = queryOne('SELECT * FROM contacts WHERE user_id = ? AND contact_id = ?', [userId, contactId]);
  if (existing) return res.json({ ok: true, already: true });
  run('INSERT INTO contacts (user_id, contact_id, type) VALUES (?, ?, ?)', [userId, contactId, type || 'friend']);
  res.json({ ok: true });
});

app.delete('/api/contacts/:userId/:contactId', (req, res) => {
  run('DELETE FROM contacts WHERE user_id = ? AND contact_id = ?', [req.params.userId, req.params.contactId]);
  res.json({ ok: true });
});

app.get('/api/users/:userId/contacts', (req, res) => {
  const contacts = queryAll('SELECT c.*, u.name, u.avatar_color FROM contacts c JOIN users u ON c.contact_id = u.id WHERE c.user_id = ?', [req.params.userId]);
  res.json(contacts);
});

// ==================== WebSocket ====================
const onlineUsers = new Map();

io.on('connection', (socket) => {
  console.log('用户连接:', socket.id);

  socket.on('user:online', (data) => {
    const { userId } = data;
    const circles = queryAll('SELECT circle_id FROM circle_members WHERE user_id = ?', [userId]);
    const circleIds = circles.map(c => c.circle_id);
    onlineUsers.set(socket.id, { userId, circleIds });
    circleIds.forEach(cid => socket.join(cid));
    circleIds.forEach(cid => socket.to(cid).emit('member:online', { userId, timestamp: Date.now() }));
  });

  socket.on('location:update', async (data) => {
    const { userId, latitude, longitude, accuracy, batteryLevel, isCharging, speed } = data;
    const info = onlineUsers.get(socket.id);
    if (!info) return;

    // 查隐私设置
    const settings = queryOne('SELECT * FROM user_settings WHERE user_id = ?', [userId]);
    if (settings?.share_paused) return; // 暂停共享

    let emitLat = latitude, emitLng = longitude;
    if (settings?.blur_location) {
      // 模糊位置：加随机偏移约500米
      emitLat += (Math.random() - 0.5) * 0.01;
      emitLng += (Math.random() - 0.5) * 0.01;
    }

    // 逆地理解码（异步，不阻塞位置上报）
    const geoResult = await reverseGeocode(latitude, longitude);
    const address = geoResult.address;

    run('INSERT INTO locations (user_id, latitude, longitude, accuracy, battery_level, is_charging, speed, address) VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
      [userId, emitLat, emitLng, accuracy || null, batteryLevel != null ? batteryLevel : null, isCharging ? 1 : 0, speed || 0, address]);

    // 更新停留
    updateStay(userId, latitude, longitude, geoResult.formatted || address);

    // 广播位置
    const payload = { userId, latitude: emitLat, longitude: emitLng, accuracy, batteryLevel, isCharging, speed, address, timestamp: Date.now() };

    // 幽灵模式：只发送给允许看到的圈子
    const user = queryOne('SELECT ghost_mode FROM users WHERE id = ?', [userId]);
    const ghostMode = user?.ghost_mode || 'off';

    info.circleIds.forEach(cid => {
      if (ghostMode === 'invisible') return; // 完全隐身
      socket.to(cid).emit('member:location', payload);
    });

    // 地理围栏检测
    if (!settings?.blur_location) { // 模糊模式下不触发围栏
      info.circleIds.forEach(cid => {
        const fences = queryAll('SELECT * FROM geofences WHERE circle_id = ?', [cid]);
        fences.forEach(fence => {
          const dist = getDistance(latitude, longitude, fence.latitude, fence.longitude);
          const wasInside =.socket?.data?.insideFences?.has(fence.id);
          if (!socket.data) socket.data = {};
          if (!socket.data.insideFences) socket.data.insideFences = new Set();

          if (dist <= fence.radius && !wasInside) {
            socket.data.insideFences.add(fence.id);
            io.to(cid).emit('geofence:alert', {
              fenceName: fence.name, userId,
              userName: queryOne('SELECT name FROM users WHERE id = ?', [userId])?.name || '未知',
              action: 'entered', distance: Math.round(dist), timestamp: Date.now()
            });
          } else if (dist > fence.radius && wasInside) {
            socket.data.insideFences.delete(fence.id);
            io.to(cid).emit('geofence:alert', {
              fenceName: fence.name, userId,
              userName: queryOne('SELECT name FROM users WHERE id = ?', [userId])?.name || '未知',
              action: 'left', distance: Math.round(dist), timestamp: Date.now()
            });
          }
        });
      });
    }

    // 碰撞检测（急减速）0){
      io.to(cid).emit('collision:alert', {
        userId, userName: queryOne('SELECT name FROM users WHERE id = ?', [userId])?.name || '未知',
        latitude, longitude, speed, timestamp: Date.now()
      });
    }
  });

  // 表情轰炸
  socket.on('emoji:bomb', (data) => {
    const info = onlineUsers.get(socket.id);
    if (!info) return;
    info.circleIds.forEach(cid => {
      io.to(cid).emit('emoji:bomb', {
        userId: data.userId,
        emoji: data.emoji || '❤️',
        count: data.count || 10,
        timestamp: Date.now()
      });
    });
  });

  // "想你"互动
  socket.on('thinking:of:you', (data) => {
    const info = onlineUsers.get(socket.id);
    if (!info) return;
    info.circleIds.forEach(cid => {
      io.to(cid).emit('thinking:of:you', {
        fromUserId: data.userId,
        fromUserName: data.userName || '某人',
        timestamp: Date.now()
      });
    });
  });

  socket.on('disconnect', () => {
    const info = onlineUsers.get(socket.id);
    if (info) {
      info.circleIds.forEach(cid => socket.to(cid).emit('member:offline', { userId: info.userId, timestamp: Date.now() }));
    }
    onlineUsers.delete(socket.id);
  });
});

// Haversine
function getDistance(lat1, lon1, lat2, lon2) {
  const R = 6371000;
  const dLat = (lat2 - lat1) * Math.PI / 180;
  const dLon = (lon2 - lon1) * Math.PI / 180;
  const a = Math.sin(dLat/2)**2 + Math.cos(lat1*Math.PI/180)*Math.cos(lat2*Math.PI/180)*Math.sin(dLon/2)**2;
  return R * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
}

// ==================== 启动 ====================
initDB().then(() => {
  server.listen(PORT, () => {
    console.log(`\n  FamilyMap 位置共享服务已启动`);
    console.log(`  本地访问: http://localhost:${PORT}`);
    console.log(`  局域网: http://<IP>:${PORT}`);
    console.log(`  逆地理解码: ${AMAP_KEY ? '已配置高德Key' : '未配置(使用坐标降级)'}\n`);
  });
}).catch(err => { console.error('DB初始化失败:', err); process.exit(1); });
