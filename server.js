const express = require('express');
const http = require('http');
const { Server } = require('socket.io');
const path = require('path');
const fs = require('fs');
const crypto = require('crypto');
const bcrypt = require('bcryptjs');
const initSqlJs = require('sql.js');
const config = require('./config');
const { initAuth, requireAuth } = require('./middleware/auth');
const { validateBody, validateQuery, schemas } = require('./middleware/validate');

const app = express();
const server = http.createServer(app);
const io = new Server(server);

const PORT = config.PORT;
const DB_PATH = config.DB_PATH;
const AMAP_KEY = config.AMAP_KEY; // 高德API Key，环境变量配置

// ==================== 工具函数 ====================

/// HTML 转义，防止 XSS 注入
function escapeHtml(str) {
  if (!str) return '';
  return str.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;').replace(/'/g, '&#39;');
}

/// XML 转义，防止 XML 注入
function escapeXml(str) {
  if (!str) return '';
  return str.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;').replace(/'/g, '&apos;');
}

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
    username TEXT UNIQUE, password_hash TEXT,
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
  // 用户-围栏状态持久化（记录上次已知是在围栏内还是外，跨重启/断线不丢失）
  db.run(`CREATE TABLE IF NOT EXISTS user_fence_states (
    user_id TEXT NOT NULL, fence_id INTEGER NOT NULL,
    is_inside INTEGER DEFAULT 0,
    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (user_id, fence_id))`);
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
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP)`);
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
  db.run(`CREATE TABLE IF NOT EXISTS emergency_contacts (
    id INTEGER PRIMARY KEY AUTOINCREMENT, user_id TEXT NOT NULL,
    name TEXT NOT NULL, phone TEXT NOT NULL, relation TEXT DEFAULT 'family',
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP)`);

  // 会话表：支持多设备登录互踢机制
  db.run(`CREATE TABLE IF NOT EXISTS sessions (
    token TEXT PRIMARY KEY,
    user_id TEXT NOT NULL,
    device_info TEXT DEFAULT '',
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    last_active DATETIME DEFAULT CURRENT_TIMESTAMP)`);

  // 索引（覆盖5.2建议：关键查询路径全部加索引）
  db.run('CREATE INDEX IF NOT EXISTS idx_loc_user_time ON locations(user_id, recorded_at DESC)');
  db.run('CREATE INDEX IF NOT EXISTS idx_loc_time ON locations(recorded_at DESC)');
  db.run('CREATE INDEX IF NOT EXISTS idx_msg_circle_time ON messages(circle_id, created_at ASC)');
  db.run('CREATE INDEX IF NOT EXISTS idx_stay_user ON stays(user_id, started_at DESC)');
  db.run('CREATE INDEX IF NOT EXISTS idx_stay_user_end ON stays(user_id, ended_at)');
  db.run('CREATE INDEX IF NOT EXISTS idx_geocode ON geocode_cache(lat_key, lng_key)');
  db.run('CREATE INDEX IF NOT EXISTS idx_fence_circle ON geofences(circle_id)');
  db.run('CREATE INDEX IF NOT EXISTS idx_circle_member_user ON circle_members(user_id)');
  db.run('CREATE INDEX IF NOT EXISTS idx_sos_status ON sos_alerts(status)');
  db.run('CREATE INDEX IF NOT EXISTS idx_sessions_user ON sessions(user_id)');
  db.run('CREATE INDEX IF NOT EXISTS idx_sessions_token ON sessions(token)');

  // 迁移：为旧表添加 username / password_hash 列（如不存在）
  try {
    const cols = queryAll("PRAGMA table_info(users)").map(c => c.name);
    if (!cols.includes('username')) { db.run('ALTER TABLE users ADD COLUMN username TEXT'); }
    if (!cols.includes('password_hash')) { db.run('ALTER TABLE users ADD COLUMN password_hash TEXT'); }
  } catch (e) { console.log('迁移提示:', e.message); }
  // 迁移后创建索引
  try { db.run('CREATE INDEX IF NOT EXISTS idx_users_username ON users(username)'); } catch(e) {}

  // 迁移：stays表添加stay_type列
  try {
    const stayCols = queryAll("PRAGMA table_info(stays)").map(c => c.name);
    if (!stayCols.includes('stay_type')) { db.run('ALTER TABLE stays ADD COLUMN stay_type TEXT DEFAULT \'other\''); }
  } catch (e) { console.log('stays迁移提示:', e.message); }

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

// ==================== 密码工具 ====================
// bcryptjs 安全哈希（纯 JS 实现，无需编译）
const BCRYPT_ROUNDS = 10;
async function hashPassword(password) {
  return bcrypt.hash(password, BCRYPT_ROUNDS);
}
async function verifyPassword(password, hash) {
  return bcrypt.compare(password, hash);
}

// ==================== 会话管理（多设备登录互踢） ====================

/// 生成会话 token（32字节随机hex字符串）
function generateSessionToken() {
  return crypto.randomBytes(32).toString('hex');
}

/// 创建新会话，并踢掉同用户的其他旧会话
/// 返回新 token
function createSession(userId, deviceInfo = '') {
  const token = generateSessionToken();
  // 删除该用户的所有旧会话（单点登录：新登录踢掉旧设备）
  const oldSessions = queryAll('SELECT token FROM sessions WHERE user_id = ?', [userId]);
  run('DELETE FROM sessions WHERE user_id = ?', [userId]);
  // 创建新会话
  run('INSERT INTO sessions (token, user_id, device_info) VALUES (?, ?, ?)', [token, userId, deviceInfo]);
  // 向旧会话对应的 Socket 连接发送 force_logout 事件
  if (oldSessions.length > 0) {
    const oldTokens = new Set(oldSessions.map(s => s.token));
    for (const [socketId, info] of onlineUsers.entries()) {
      if (info.userId === userId && oldTokens.has(info.token)) {
        console.log(`[互踢] 用户 ${userId} 在新设备登录，踢掉旧 socket ${socketId}`);
        io.to(socketId).emit('force_logout', { reason: '账号已在其他设备登录' });
      }
    }
  }
  return token;
}

/// 验证会话 token 是否有效，返回 userId 或 null
function verifySession(token) {
  if (!token) return null;
  const session = queryOne('SELECT user_id FROM sessions WHERE token = ?', [token]);
  if (!session) return null;
  // 更新最后活跃时间
  run("UPDATE sessions SET last_active = datetime('now') WHERE token = ?", [token]);
  return session.user_id;
}

/// 清理超过7天未活跃的过期会话
function cleanExpiredSessions() {
  run("DELETE FROM sessions WHERE last_active < datetime('now', '-7 days')");
}

// 每小时清理一次过期会话
setInterval(cleanExpiredSessions, 3600000);
// 注意：cleanExpiredSessions() 不在此处调用，因为 db 对象尚未初始化
// 改在 initDB() 完成后调用

// ==================== 逆地理解码 ====================
const https = require('https');

// WGS-84 → GCJ-02 坐标转换（供逆地理解码用，高德API需GCJ-02坐标）
function wgs84ToGcj02(wgsLat, wgsLng) {
  const a = 6378245.0;
  const ee = 0.00669342162296594323;
  if (wgsLng < 72.004 || wgsLng > 137.8347 || wgsLat < 0.8293 || wgsLat > 55.8271) return { lat: wgsLat, lng: wgsLng };
  let dLat = _transformLat(wgsLng - 105.0, wgsLat - 35.0);
  let dLng = _transformLng(wgsLng - 105.0, wgsLat - 35.0);
  const radLat = wgsLat / 180.0 * Math.PI;
  let magic = Math.sin(radLat);
  magic = 1 - ee * magic * magic;
  const sqrtMagic = Math.sqrt(magic);
  dLat = (dLat * 180.0) / ((a * (1 - ee)) / (magic * sqrtMagic) * Math.PI);
  dLng = (dLng * 180.0) / (a / sqrtMagic * Math.cos(radLat) * Math.PI);
  return { lat: wgsLat + dLat, lng: wgsLng + dLng };
}
function _transformLat(x, y) {
  let ret = -100.0 + 2.0*x + 3.0*y + 0.2*y*y + 0.1*x*y + 0.2*Math.sqrt(Math.abs(x));
  ret += (20.0*Math.sin(6.0*x*Math.PI) + 20.0*Math.sin(2.0*x*Math.PI)) * 2.0/3.0;
  ret += (20.0*Math.sin(y*Math.PI) + 40.0*Math.sin(y/3.0*Math.PI)) * 2.0/3.0;
  ret += (160.0*Math.sin(y/12.0*Math.PI) + 320*Math.sin(y*Math.PI/30.0)) * 2.0/3.0;
  return ret;
}
function _transformLng(x, y) {
  let ret = 300.0 + x + 2.0*y + 0.1*x*x + 0.1*x*y + 0.1*Math.sqrt(Math.abs(x));
  ret += (20.0*Math.sin(6.0*x*Math.PI) + 20.0*Math.sin(2.0*x*Math.PI)) * 2.0/3.0;
  ret += (20.0*Math.sin(x*Math.PI) + 40.0*Math.sin(x/3.0*Math.PI)) * 2.0/3.0;
  ret += (150.0*Math.sin(x/12.0*Math.PI) + 300.0*Math.sin(x/30.0*Math.PI)) * 2.0/3.0;
  return ret;
}

// 逆地理解码节流：同一用户30秒内只调一次高德API
const _geocodeLastCall = new Map();
const GEOCODE_THROTTLE_MS = 30000;

// 碰撞检测：多重确认 + 降噪
// _collisionState 记录每个用户的碰撞检测状态
// { lastSpeed, lastTime, suspiciousCount, lastAlertTime, speedWindow }
const _collisionState = new Map();
const _lowBatterySent = new Map();

// 缓存有效期分级：
// - FRESH 天内：直接用，不需要任何操作
// - FRESH ~ STALE 天：先用旧值返回，后台异步刷新（用户无感知）
// - 超过 STALE 天：同步刷新，拿到最新值再返回
const CACHE_FRESH_DAYS = 90;   // 3个月内放心用
const CACHE_STALE_DAYS = 180;  // 半年后必须刷新

async function reverseGeocode(lat, lng, { forceRefresh = false } = {}) {
  // 1. 查缓存（精度3位小数≈110m，比2位≈1km更精确，同时保持合理命中率）
  const latKey = lat.toFixed(3);
  const lngKey = lng.toFixed(3);
  const cached = queryOne('SELECT * FROM geocode_cache WHERE lat_key = ? AND lng_key = ?', [latKey, lngKey]);

  if (cached && !forceRefresh) {
    const ageDays = cached.cached_at
      ? (Date.now() - new Date(cached.cached_at + 'Z').getTime()) / 86400000
      : 999; // 无时间戳视为很旧

    if (ageDays < CACHE_FRESH_DAYS) {
      // 新鲜：直接返回
      return { address: cached.address, formatted: cached.formatted };
    }

    if (ageDays < CACHE_STALE_DAYS) {
      // 有点旧但还能用：先返回旧值，后台悄悄刷新
      _backgroundRefresh(lat, lng, latKey, lngKey, cached);
      return { address: cached.address, formatted: cached.formatted };
    }
    // 超过180天：太旧了，同步刷新（下面继续调API）
  }

  // 2. 调高德API获取新地址
  if (!AMAP_KEY) {
    const fallback = `${lat.toFixed(4)},${lng.toFixed(4)}(坐标)`;
    return { address: fallback, formatted: fallback };
  }

  // 3. WGS-84转GCJ-02再调高德API（高德期望GCJ-02坐标）
  const gcj = wgs84ToGcj02(lat, lng);

  return new Promise((resolve) => {
    const url = `https://restapi.amap.com/v3/geocode/regeo?key=${AMAP_KEY}&location=${gcj.lng},${gcj.lat}&extensions=base`;
    const req = https.get(url, { timeout: 5000 }, (res) => {
      let data = '';
      res.on('data', chunk => data += chunk);
      res.on('end', () => {
        try {
          const json = JSON.parse(data);
          const fallbackAddr = `位置(${lat.toFixed(2)},${lng.toFixed(2)})`;
          if (json.status !== '1') {
            resolve({ address: fallbackAddr, formatted: '' });
            return;
          }
          const address = json.regeocode?.formatted_address || fallbackAddr;
          const comp = json.regeocode?.addressComponent || {};
          const formatted = comp.township || comp.street || comp.district ||
            address.split('区').pop()?.substring(0, 20) || address;
          // 存缓存：已有则更新（刷新地址+时间戳），无则插入
          if (cached) {
            run('UPDATE geocode_cache SET address = ?, formatted = ?, cached_at = datetime("now") WHERE lat_key = ? AND lng_key = ?',
              [address, formatted, latKey, lngKey]);
          } else {
            run('INSERT INTO geocode_cache (lat_key, lng_key, address, formatted) VALUES (?, ?, ?, ?)',
              [latKey, lngKey, address, formatted]);
          }
          resolve({ address, formatted, precision: address.length > 20 ? 'high' : 'low' });
        } catch (e) {
          resolve({ address: `位置(${lat.toFixed(2)},${lng.toFixed(2)})`, formatted: '' });
        }
      });
    });
    req.on('error', () => {
      resolve({ address: `位置(${lat.toFixed(2)},${lng.toFixed(2)})`, formatted: '' });
    });
    req.on('timeout', () => {
      req.destroy();
      resolve({ address: `位置(${lat.toFixed(2)},${lng.toFixed(2)})`, formatted: '' });
    });
  });
}

/// 后台异步刷新：用户无感知，静默更新旧缓存
/// 加锁防止同一坐标并发刷新
const _refreshingKeys = new Set();
function _backgroundRefresh(lat, lng, latKey, lngKey, cached) {
  const lockKey = `${latKey},${lngKey}`;
  if (_refreshingKeys.has(lockKey)) return; // 正在刷新中，跳过
  _refreshingKeys.add(lockKey);

  // 不 await，放在后台执行
  reverseGeocode(lat, lng, { forceRefresh: true })
    .then(result => {
      if (result.address && !result.address.includes('位置(')) {
        run('UPDATE geocode_cache SET address = ?, formatted = ?, cached_at = datetime("now") WHERE lat_key = ? AND lng_key = ?',
          [result.address, result.formatted || '', latKey, lngKey]);
      }
    })
    .catch(() => {}) // 静默失败，不影响用户
    .finally(() => _refreshingKeys.delete(lockKey));
}

// ==================== 停留计算 ====================
// 改进：
// 1) 增大漂移容差到200米
// 2) 时间衰减续接
// 3) 停留类型推断
// 4) 超时自动关闭
// 5) 移动中不创建新停留，只在确认真正静止后才更新
// 6) 离开确认：需要连续2次上报距离>200m才结束停留，避免GPS漂移误报

// 离开确认计数器：userId → {count, lat, lng}
const _leaveConfirm = new Map();

function updateStay(userId, lat, lng, address, speed) {
  speed = speed || 0;
  const isMoving = speed > 3.0; // 3m/s ≈ 10.8km/h，步行以上速度视为移动

  // 查最近未结束的停留
  const active = queryOne('SELECT * FROM stays WHERE user_id = ? AND ended_at IS NULL ORDER BY started_at DESC LIMIT 1', [userId]);

  if (active) {
    const dist = getDistance(lat, lng, active.latitude, active.longitude);
    if (dist < 200) {
      // 还在同一地点（容差200米，覆盖GPS漂移），不操作
      _leaveConfirm.delete(userId); // 重置离开确认
      return;
    } else {
      // 距离>200m，但需要确认是真的离开了还是GPS跳点
      // 移动中不急着结束停留，等确认静止再说
      if (isMoving) {
        // 在移动，跳过停留操作（不结束、不创建、不广播）
        return;
      }

      // 静止但离停留点远了，需要连续2次确认才结束
      const lc = _leaveConfirm.get(userId) || { count: 0, lat: 0, lng: 0 };
      // 确认位置和上次差不多（不是在快速移动中的不同位置）
      const confirmDist = getDistance(lat, lng, lc.lat, lc.lng);
      if (lc.count > 0 && confirmDist < 200) {
        // 第2次确认：真的离开了
        _leaveConfirm.delete(userId);
      } else {
        // 第1次确认，记录下来等下次
        _leaveConfirm.set(userId, { count: 1, lat, lng });
        return; // 不结束，等下次确认
      }

      // 离开了，结束当前停留
      // 注意：SQLite datetime("now") 存的是 UTC，必须加 'Z' 后缀让 JS 按UTC解析，否则会多出时区偏移
      const started = new Date(active.started_at + 'Z');
      const ended = new Date();
      const dur = Math.round((ended - started) / 60000);
      // 推断停留类型
      const stayType = inferStayType(active.address || address || '');
      run('UPDATE stays SET ended_at = datetime("now"), duration_minutes = ?, stay_type = ? WHERE id = ?', [dur, stayType, active.id]);

      // 广播离开通知
      const user = queryOne('SELECT name FROM users WHERE id = ?', [userId]);
      const info = [...onlineUsers.values()].find(i => i.userId === userId);
      if (info) {
        info.circleIds.forEach(cid => {
          io.to(cid).emit('trip:report', {
            userId, userName: user?.name || '未知',
            action: 'left', address: active.address || '某地',
            duration: dur, stayType, timestamp: Date.now()
          });
        });
      }

      // 4.6 到家/离家通知
      if (stayType === 'home') {
        const homeDist = getDistance(lat, lng, active.latitude, active.longitude);
        if (homeDist > 200) {
          const homeInfo = [...onlineUsers.values()].find(i => i.userId === userId);
          if (homeInfo) {
            homeInfo.circleIds.forEach(cid => {
              io.to(cid).emit('home:status', {
                userId, userName: user?.name || '未知', action: 'left', address: active.address,
                distance: Math.round(homeDist), timestamp: Date.now()
              });
            });
          }
        }
      }
    }
  }

  // 移动中不创建新停留（等停下来再说）
  if (isMoving) return;

  // 时间衰减续接：离开越久，续接要求越严格
  const recent = queryOne(
    `SELECT * FROM stays WHERE user_id = ? AND ended_at IS NOT NULL AND ended_at >= datetime("now", "-2 hours") ORDER BY ended_at DESC LIMIT 1`,
    [userId]
  );

  if (recent) {
    const dist = getDistance(lat, lng, recent.latitude, recent.longitude);
    const endedAt = new Date(recent.ended_at + 'Z');
    const elapsedMinutes = (Date.now() - endedAt.getTime()) / 60000;
    // 时间衰减：30分钟内200m续接，30分钟-2小时内要求100m内
    const maxDist = elapsedMinutes < 30 ? 200 : 100;

    if (dist < maxDist) {
      // 回到附近，续接停留
      run('INSERT INTO stays (user_id, latitude, longitude, address, stay_type, started_at) VALUES (?, ?, ?, ?, ?, datetime("now"))',
        [userId, recent.latitude, recent.longitude, recent.address || address || '', recent.stay_type || inferStayType(recent.address || address || '')]);
      return;
    }
  }

  // 全新地点，创建新停留
  const stayType = inferStayType(address || '');
  run('INSERT INTO stays (user_id, latitude, longitude, address, stay_type, started_at) VALUES (?, ?, ?, ?, ?, datetime("now"))',
    [userId, lat, lng, address || '', stayType]);
}

/// 根据地址关键词推断停留场景
function inferStayType(address) {
  if (!address) return 'other';
  if (/小区|公寓|花园|家园|家园|大厦|家园/.test(address)) return 'home';
  if (/公司|科技|大厦|园区|写字楼/.test(address)) return 'work';
  if (/学校|大学|学院|中学|小学/.test(address)) return 'school';
  if (/餐厅|饭店|美食|火锅|面馆|小吃/.test(address)) return 'food';
  if (/商场|购物|超市|影院|KTV|娱乐/.test(address)) return 'fun';
  if (/医院|诊所|卫生院/.test(address)) return 'hospital';
  return 'other';
}

// 超时关闭：每5分钟检查一次，如果停留超过24小时未结束，自动关闭
setInterval(() => {
  try {
    const stale = queryAll('SELECT * FROM stays WHERE ended_at IS NULL AND started_at < datetime("now", "-24 hours")');
    stale.forEach(s => {
      const dur = Math.round((Date.now() - new Date(s.started_at + 'Z').getTime()) / 60000);
      run('UPDATE stays SET ended_at = datetime("now"), duration_minutes = ? WHERE id = ?', [dur, s.id]);
    });
  } catch (_) {}
}, 300000);

// ==================== 存活检测 ====================
function checkAlive() {
  const users = queryAll('SELECT id, name FROM users');
  users.forEach(u => {
    const lastLoc = queryOne('SELECT recorded_at FROM locations WHERE user_id = ? ORDER BY recorded_at DESC LIMIT 1', [u.id]);
    if (!lastLoc) return;
    const lastTime = new Date(lastLoc.recorded_at + 'Z');
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
// 注册：用户名 + 密码 + 昵称
app.post('/api/register', validateBody(schemas.register), async (req, res) => {
  const { username, password, name } = req.body;

  // 检查用户名是否已存在
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
    // 注册同时也创建会话
    const token = createSession(id, 'register');
    res.json({ id, name, avatar_color, username, token });
  } catch (e) {
    res.status(500).json({ error: '注册失败: ' + e.message });
  }
});

// 登录：用户名 + 密码，返回 session token
app.post('/api/login', validateBody(schemas.login), async (req, res) => {
  const { username, password, device_info } = req.body;

  const user = queryOne('SELECT * FROM users WHERE username = ?', [username]);
  if (!user) return res.status(401).json({ error: '用户名或密码错误' });

  // 支持旧密码自动迁移（SHA-256 → bcrypt）
  let passwordValid = false;
  if (user.password_hash && user.password_hash.startsWith('$2a$')) {
    // 新格式 (bcryptjs 使用 $2a$ 前缀)
    passwordValid = await bcrypt.compare(password, user.password_hash);
  } else if (user.password_hash) {
    // 旧格式 (SHA-256)，验证后自动迁移
    const oldHash = crypto.createHash('sha256').update('FamilyMap2026Salt' + password).digest('hex');
    if (oldHash === user.password_hash) {
      passwordValid = true;
      // 自动迁移到 bcryptjs
      const newHash = await bcrypt.hash(password, BCRYPT_ROUNDS);
      run('UPDATE users SET password_hash = ? WHERE id = ?', [newHash, user.id]);
      console.log(`[迁移] 用户 ${user.id} 密码已自动迁移到 bcrypt`);
    }
  }

  if (!passwordValid) {
    return res.status(401).json({ error: '用户名或密码错误' });
  }

  // 创建新会话并踢掉同用户的其他旧设备
  const token = createSession(user.id, device_info || '');

  res.json({
    id: user.id,
    name: user.name,
    avatar_color: user.avatar_color,
    username: user.username,
    mood: user.mood,
    is_sleeping: user.is_sleeping,
    ghost_mode: user.ghost_mode,
    token,  // 会话 token，客户端需保存
  });
});

// 旧版注册（兼容无密码模式，自动分配用户名）
app.post('/api/users', (req, res) => {
  const { name } = req.body;
  if (!name) return res.status(400).json({ error: '名字不能为空' });
  const id = 'u_' + Date.now().toString(36) + Math.random().toString(36).substr(2, 5);
  const colors = ['#4F46E5','#EC4899','#10B981','#F59E0B','#EF4444','#8B5CF6','#06B6D4','#F97316'];
  const avatar_color = colors[Math.floor(Math.random() * colors.length)];
  // 自动生成用户名（auto_加ID后缀）
  const autoUsername = 'auto_' + id.substring(2);
  try {
    run('INSERT INTO users (id, name, avatar_color, username) VALUES (?, ?, ?, ?)', [id, name, avatar_color, autoUsername]);
  } catch (e) {
    // 如果自动用户名冲突，再试一次
    const alt = 'auto_' + id.substring(2) + Math.floor(Math.random()*100);
    run('INSERT INTO users (id, name, avatar_color, username) VALUES (?, ?, ?, ?)', [id, name, avatar_color, alt]);
  }
  run('INSERT INTO user_settings (user_id) VALUES (?)', [id]);
  const token = createSession(id, 'legacy');
  res.json({ id, name, avatar_color, token });
});

app.get('/api/users/:userId', (req, res) => {
  const user = queryOne('SELECT * FROM users WHERE id = ?', [req.params.userId]);
  if (!user) return res.status(404).json({ error: '用户不存在' });
  // 删除敏感字段：密码哈希不应暴露给前端
  delete user.password_hash;
  res.json(user);
});

// 登出：删除当前会话 token
app.post('/api/logout', (req, res) => {
  const { token } = req.body;
  if (token) {
    run('DELETE FROM sessions WHERE token = ?', [token]);
  }
  res.json({ success: true });
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

// --- 圈子 ---
app.post('/api/circles', requireAuth, (req, res) => {
  const { name, userId } = req.body;
  if (!name || !userId) return res.status(400).json({ error: '参数不完整' });
  const id = 'c_' + Date.now().toString(36) + Math.random().toString(36).substr(2, 5);
  const invite_code = Math.random().toString(36).substr(2, 6).toUpperCase();
  run('INSERT INTO circles (id, name, invite_code) VALUES (?, ?, ?)', [id, name, invite_code]);
  run('INSERT INTO circle_members (circle_id, user_id) VALUES (?, ?)', [id, userId]);
  res.json({ id, name, invite_code });
});

app.post('/api/circles/join', requireAuth, (req, res) => {
  const { inviteCode, userId } = req.body;
  if (!inviteCode || !userId) return res.status(400).json({ error: '参数不完整' });
  const circle = queryOne('SELECT * FROM circles WHERE invite_code = ?', [inviteCode]);
  if (!circle) return res.status(404).json({ error: '邀请码无效' });
  const existing = queryOne('SELECT * FROM circle_members WHERE circle_id = ? AND user_id = ?', [circle.id, userId]);
  if (existing) return res.json({ circle, alreadyMember: true });
  run('INSERT INTO circle_members (circle_id, user_id) VALUES (?, ?)', [circle.id, userId]);

  // 广播有人加入圈子，让其他成员刷新
  const userName = queryOne('SELECT name FROM users WHERE id = ?', [userId])?.name || '新成员';
  io.to(circle.id).emit('circle:join', {
    circleId: circle.id, userId, userName, timestamp: Date.now()
  });

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
  // 为每个成员添加当前停留信息 + 补全空地址
  Object.values(latest).forEach(m => {
    // 如果最新记录地址为空，回溯取该用户最近一条有地址的记录
    if (!m.address || m.address.trim() === '') {
      const lastAddr = queryOne(
        "SELECT address FROM locations WHERE user_id = ? AND address IS NOT NULL AND address != '' ORDER BY recorded_at DESC LIMIT 1",
        [m.id]
      );
      if (lastAddr) m.address = lastAddr.address;
    }
    const stay = queryOne('SELECT * FROM stays WHERE user_id = ? AND ended_at IS NULL ORDER BY started_at DESC LIMIT 1', [m.id]);
    if (stay) {
      const mins = Math.round((Date.now() - new Date(stay.started_at + 'Z').getTime()) / 60000);
      m.stay_address = stay.address;
      m.stay_minutes = mins;
      m.stay_started_at = stay.started_at;
    }
  });
  res.json(Object.values(latest));
});

// --- 位置 ---
app.get('/api/users/:userId/locations', (req, res) => {
  const hours = Math.min(Math.max(parseInt(req.query.hours) || 24, 1), 720);
  const locations = queryAll(`SELECT * FROM locations
    WHERE user_id = ? AND recorded_at >= datetime('now', '-' || ? || ' hours') ORDER BY recorded_at ASC`,
    [req.params.userId, hours]);
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

app.post('/api/circles/:circleId/geofences', requireAuth, (req, res) => {
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

// --- 停留记录 ---
app.get('/api/users/:userId/stays', (req, res) => {
  const days = Math.min(Math.max(parseInt(req.query.days) || 7, 1), 365);
  const stays = queryAll(`SELECT * FROM stays WHERE user_id = ? AND started_at >= datetime('now', '-' || ? || ' days') ORDER BY started_at DESC`,
    [req.params.userId, days]);
  res.json(stays);
});

// --- 行程时间线（某天的所有停留+移动） ---
app.get('/api/users/:userId/timeline', (req, res) => {
  const date = req.query.date || new Date().toISOString().split('T')[0];
  const stays = queryAll(`SELECT * FROM stays WHERE user_id = ? AND date(started_at) = ? ORDER BY started_at ASC`, [req.params.userId, date]);
  res.json(stays);
});

// --- 历史轨迹（某天的GPS位置点序列，用于画轨迹线） ---
app.get('/api/users/:userId/track', (req, res) => {
  const date = req.query.date || new Date().toISOString().split('T')[0];
  const nextDay = new Date(date);
  nextDay.setDate(nextDay.getDate() + 1);
  const nextDate = nextDay.toISOString().split('T')[0];
  // 每分钟取一个点（避免点太多），按时间排序
  const points = queryAll(
    `SELECT id, latitude, longitude, speed, address, recorded_at FROM locations
     WHERE user_id = ? AND recorded_at >= ? AND recorded_at < ?
     GROUP BY strftime('%Y-%m-%d %H:%M', recorded_at)
     ORDER BY recorded_at ASC`,
    [req.params.userId, date, nextDate]
  );
  res.json(points);
});

// --- SOS ---
app.post('/api/sos', requireAuth, async (req, res) => {
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

app.put('/api/sos/:id/resolve', requireAuth, (req, res) => {
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

app.post('/api/circles/:circleId/messages', requireAuth, (req, res) => {
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

app.post('/api/users/:userId/footprints', requireAuth, (req, res) => {
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

// --- 用户设置 ---
app.get('/api/users/:userId/settings', (req, res) => {
  let s = queryOne('SELECT * FROM user_settings WHERE user_id = ?', [req.params.userId]);
  if (!s) { run('INSERT INTO user_settings (user_id) VALUES (?)', [req.params.userId]); s = { user_id: req.params.userId }; }
  res.json(s);
});

app.put('/api/users/:userId/settings', requireAuth, (req, res) => {
  const fields = []; const values = [];
  ['blur_location', 'share_paused', 'trail_skin', 'nickname_color', 'dark_mode', 'lang'].forEach(f => {
    if (req.body[f] !== undefined) { fields.push(`${f} = ?`); values.push(req.body[f]); }
  });
  if (fields.length > 0) { values.push(req.params.userId); run(`UPDATE user_settings SET ${fields.join(', ')} WHERE user_id = ?`, values); }
  res.json({ ok: true });
});

// --- 世界迷雾（统计去过的城市/国家） ---
app.get('/api/users/:userId/world', (req, res) => {
  // 用3位精度匹配缓存（与reverseGeocode一致）
  const locations = queryAll('SELECT DISTINCT ROUND(latitude, 3) as lat_key, ROUND(longitude, 3) as lng_key FROM locations WHERE user_id = ?', [req.params.userId]);
  // 用1位精度计算网格数（约11km网格）
  const gridRows = queryAll('SELECT DISTINCT CAST(ROUND(latitude, 1) * 10 AS INTEGER) as lat_grid, CAST(ROUND(longitude, 1) * 10 AS INTEGER) as lng_grid FROM locations WHERE user_id = ?', [req.params.userId]);
  const cities = new Set();
  locations.forEach(l => {
    // 用3位精度查缓存，与存储精度一致
    const addr = queryOne('SELECT address FROM geocode_cache WHERE lat_key = ? AND lng_key = ?', [l.lat_key.toFixed(3), l.lng_key.toFixed(3)]);
    if (addr?.address) {
      const match = addr.address.match(/市([^区县市]+[区县市])/);
      if (match) cities.add(match[1]);
    }
  });
  res.json({ gridCount: gridRows.length, cities: [...cities], cityCount: cities.size });
});

// --- 联系人/好友 ---
app.post('/api/contacts', requireAuth, (req, res) => {
  const { userId, contactId, type } = req.body;
  const existing = queryOne('SELECT * FROM contacts WHERE user_id = ? AND contact_id = ?', [userId, contactId]);
  if (existing) return res.json({ ok: true, already: true });
  run('INSERT INTO contacts (user_id, contact_id, type) VALUES (?, ?, ?)', [userId, contactId, type || 'friend']);
  res.json({ ok: true });
});

app.delete('/api/contacts/:userId/:contactId', requireAuth, (req, res) => {
  run('DELETE FROM contacts WHERE user_id = ? AND contact_id = ?', [req.params.userId, req.params.contactId]);
  res.json({ ok: true });
});

app.get('/api/users/:userId/contacts', (req, res) => {
  const contacts = queryAll('SELECT c.*, u.name, u.avatar_color FROM contacts c JOIN users u ON c.contact_id = u.id WHERE c.user_id = ?', [req.params.userId]);
  res.json(contacts);
});

// --- 4.1 ETA到达预估 ---
app.get('/api/eta', (req, res) => {
  const { fromLat, fromLng, toLat, toLng, speed } = req.query;
  if (!fromLat || !fromLng || !toLat || !toLng) return res.status(400).json({ error: '参数不完整' });
  const dist = getDistance(parseFloat(fromLat), parseFloat(fromLng), parseFloat(toLat), parseFloat(toLng));
  const spd = parseFloat(speed) || 5; // 默认步行速度5m/s
  const etaSeconds = Math.round(dist / Math.max(spd, 0.5));
  res.json({ distance: Math.round(dist), etaSeconds, etaMinutes: Math.round(etaSeconds / 60) });
});

// --- 4.2 位置分享链接（生成临时token） ---
const _shareTokens = new Map(); // token → {userId, lat, lng, expires}
app.post('/api/share-link', requireAuth, (req, res) => {
  const { userId, latitude, longitude, durationMinutes, trackMode } = req.body;
  if (!userId || !latitude || !longitude) return res.status(400).json({ error: '参数不完整' });
  const token = crypto.randomBytes(8).toString('hex');
  const expires = Date.now() + (durationMinutes || 60) * 60000;
  _shareTokens.set(token, { userId, latitude, longitude, expires, trackMode: !!trackMode });
  // 清理过期token
  for (const [k, v] of _shareTokens) { if (v.expires < Date.now()) _shareTokens.delete(k); }
  res.json({ token, url: `http://www.zhp0104.fun:${PORT}/share/${token}`, expiresAt: new Date(expires).toISOString() });
});

// 行程分享前端页面（非API）
app.get('/share/:token', (req, res) => {
  const data = _shareTokens.get(req.params.token);
  if (!data || data.expires < Date.now()) {
    return res.status(404).send(`<!DOCTYPE html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>链接已过期</title><style>body{font-family:-apple-system,BlinkMacSystemFont,sans-serif;display:flex;justify-content:center;align-items:center;height:100vh;margin:0;background:#f1f5f9;color:#64748b}</style></head><body><div style="text-align:center"><h2>链接已过期或不存在</h2><p>请向分享者索要新的链接</p></div></body></html>`);
  }
  const user = queryOne('SELECT name, avatar_color FROM users WHERE id = ?', [data.userId]);
  // Flutter 传入的 latitude/longitude 已经是 GCJ-02（前端做了 _wgs84ToGcj02 转换后传入）
  // 但行程模式从数据库取的是 WGS-84 原始坐标，需要转换
  let lat = data.latitude, lng = data.longitude;
  let isGcj02 = true; // Flutter 传入的坐标已经是 GCJ-02
  if (data.trackMode) {
    const latest = queryOne('SELECT latitude, longitude FROM locations WHERE user_id = ? ORDER BY recorded_at DESC LIMIT 1', [data.userId]);
    if (latest) { lat = latest.latitude; lng = latest.longitude; isGcj02 = false; }
  }
  // 如果坐标是 WGS-84，转换为 GCJ-02（高德地图需要）
  const gcjCoords = isGcj02 ? { lat, lng } : wgs84ToGcj02(lat, lng);
  res.send(`<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>${escapeHtml(user?.name) || '家人'}的位置 - FamilyMap</title>
<style>
*{margin:0;padding:0;box-sizing:border-box}
body{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;background:#0f172a;color:#e2e8f0;height:100vh;display:flex;flex-direction:column}
.header{padding:16px 20px;background:#1e293b;display:flex;align-items:center;gap:12px;border-bottom:1px solid #334155}
.avatar{width:40px;height:40px;border-radius:50%;display:flex;align-items:center;justify-content:center;font-size:18px;font-weight:700;color:#fff}
.name{font-size:16px;font-weight:600}
.status{font-size:12px;color:#94a3b8}
.mode-tag{font-size:11px;background:#3b82f6;color:#fff;padding:2px 8px;border-radius:10px;margin-left:8px}
#map{flex:1;width:100%}
.info-bar{padding:12px 20px;background:#1e293b;border-top:1px solid #334155;font-size:13px;color:#94a3b8;text-align:center}
.expired{display:none;padding:20px;text-align:center;color:#ef4444}
</style>
</head>
<body>
<div class="header">
  <div class="avatar" style="background:${user?.avatar_color || '#3b82f6'}">${escapeHtml((user?.name || '?')[0])}</div>
  <div><div class="name">${escapeHtml(user?.name) || '未知'}${data.trackMode ? '<span class="mode-tag">行程追踪中</span>' : ''}</div><div class="status">位置分享</div></div>
</div>
<div id="map"></div>
<div class="info-bar" id="info">加载地图中...</div>
<div class="expired" id="expired">链接已过期，请向分享者索要新的链接</div>
<script>
var lat0=${gcjCoords.lat},lng0=${gcjCoords.lng},token="${req.params.token}",trackMode=${data.trackMode ? 'true' : 'false'},expiresAt=${data.expires};
function loadScript(src,cb){var s=document.createElement('script');s.src=src;s.onload=cb;document.head.appendChild(s)}
function initMap(){
  var map=new AMap.Map('map',{center:[lng0,lat0],zoom:16,mapStyle:'amap://styles/dark',resizeEnable:true});
  var marker=new AMap.Marker({position:[lng0,lat0],title:'${escapeHtml(user?.name) || '家人'}'});
  map.add(marker);
  document.getElementById('info').textContent='最后更新: '+new Date().toLocaleTimeString('zh-CN');
  if(trackMode){setInterval(function(){
    if(Date.now()>expiresAt){document.getElementById('expired').style.display='block';document.getElementById('info').textContent='链接已过期';return}
    fetch('/api/share/'+token).then(function(r){return r.json()}).then(function(d){
      if(d.latitude&&d.longitude){marker.setPosition([d.longitude,d.latitude]);map.setCenter([d.longitude,d.latitude]);
        document.getElementById('info').textContent='实时位置 · '+new Date().toLocaleTimeString('zh-CN')}
    }).catch(function(){})
  },5000)}
}
loadScript('https://webapi.amap.com/maps?v=2.0&key=a80218fd754f53e944a193daa922e438',initMap);
</script>
</body>
</html>`);
});

app.get('/api/share/:token', (req, res) => {
  const data = _shareTokens.get(req.params.token);
  if (!data || data.expires < Date.now()) return res.status(404).json({ error: '链接已过期或不存在' });
  const user = queryOne('SELECT name, avatar_color FROM users WHERE id = ?', [data.userId]);
  // 行程模式：返回用户最新位置（非创建时的固定位置）
  let lat = data.latitude, lng = data.longitude;
  let isGcj02 = true; // Flutter 传入的坐标已经是 GCJ-02
  if (data.trackMode) {
    const latest = queryOne('SELECT latitude, longitude FROM locations WHERE user_id = ? ORDER BY recorded_at DESC LIMIT 1', [data.userId]);
    if (latest) { lat = latest.latitude; lng = latest.longitude; isGcj02 = false; }
  }
  // 统一输出 GCJ-02 坐标供高德地图使用
  const gcjCoords = isGcj02 ? { lat, lng } : wgs84ToGcj02(lat, lng);
  res.json({ name: user?.name, latitude: gcjCoords.lat, longitude: gcjCoords.lng, trackMode: !!data.trackMode });
});

// --- 4.3 紧急联系人 ---
app.get('/api/users/:userId/emergency-contacts', (req, res) => {
  const contacts = queryAll('SELECT * FROM emergency_contacts WHERE user_id = ?', [req.params.userId]);
  res.json(contacts);
});

app.post('/api/users/:userId/emergency-contacts', requireAuth, (req, res) => {
  const { name, phone, relation } = req.body;
  if (!name || !phone) return res.status(400).json({ error: '姓名和电话不能为空' });
  run('INSERT INTO emergency_contacts (user_id, name, phone, relation) VALUES (?, ?, ?, ?)',
    [req.params.userId, name, phone, relation || 'family']);
  res.json({ ok: true });
});

app.delete('/api/emergency-contacts/:id', requireAuth, (req, res) => {
  run('DELETE FROM emergency_contacts WHERE id = ?', [req.params.id]);
  res.json({ ok: true });
});

// --- 4.8 位置历史导出 GPX ---
app.get('/api/users/:userId/export/gpx', (req, res) => {
  const date = req.query.date || new Date().toISOString().split('T')[0];
  const nextDay = new Date(date); nextDay.setDate(nextDay.getDate() + 1);
  const nextDate = nextDay.toISOString().split('T')[0];
  const points = queryAll(
    `SELECT latitude, longitude, speed, accuracy, recorded_at FROM locations
     WHERE user_id = ? AND recorded_at >= ? AND recorded_at < ? ORDER BY recorded_at ASC`,
    [req.params.userId, date, nextDate]
  );
  const user = queryOne('SELECT name FROM users WHERE id = ?', [req.params.userId]);
  const trkpts = points.map(p =>
    `    <trkpt lat="${p.latitude}" lon="${p.longitude}"><ele>0</ele><time>${new Date(p.recorded_at + 'Z').toISOString()}</time><speed>${p.speed || 0}</speed></trkpt>`
  ).join('\n');
  const gpx = `<?xml version="1.0" encoding="UTF-8"?>
<gpx version="1.1" creator="FamilyMap">
  <trk><name>${escapeXml(user?.name) || 'Unknown'} - ${date}</name>
  <trkseg>
${trkpts}
  </trkseg></trk>
</gpx>`;
  res.set('Content-Type', 'application/gpx+xml');
  res.set('Content-Disposition', `attachment; filename="familymap-${date}.gpx"`);
  res.send(gpx);
});

// 4.5 位置历史热力图 - 将位置点按网格聚合，返回 {lat, lng, intensity}
app.get('/api/users/:userId/heatmap', (req, res) => {
  const days = parseInt(req.query.days) || 7;
  const grid = new Map(); // key: "lat_grid,lng_grid" → {lat, lng, count}

  const daysParam = Math.min(Math.max(parseInt(req.query.days) || 7, 1), 365);
  const rows = queryAll(
    `SELECT latitude, longitude FROM locations
     WHERE user_id = ? AND recorded_at >= datetime('now', '-' || ? || ' days')
       AND latitude IS NOT NULL AND longitude IS NOT NULL`,
    [req.params.userId, daysParam]
  );

  for (const r of rows) {
    // 网格精度 0.001度 ≈ 100m
    const latG = (r.latitude * 1000 | 0) / 1000;
    const lngG = (r.longitude * 1000 | 0) / 1000;
    const key = `${latG},${lngG}`;
    if (grid.has(key)) {
      grid.get(key).count++;
    } else {
      grid.set(key, { lat: latG + 0.0005, lng: lngG + 0.0005, count: 1 }); // 中心点
    }
  }

  // 转为数组，计算 intensity (0-1)
  const points = [...grid.values()];
  const maxCount = Math.max(1, ...points.map(p => p.count));
  const result = points.map(p => ({
    lat: p.lat,
    lng: p.lng,
    intensity: Math.round((p.count / maxCount) * 100) / 100,
    count: p.count
  })).sort((a, b) => b.intensity - a.intensity); // 按强度降序

  res.json({ days, totalPoints: rows.length, heatmap: result });
});

// 4.9 驾驶行为评分 - 分析速度数据，计算安全评分
app.get('/api/users/:userId/driving-score', (req, res) => {
  const days = parseInt(req.query.days) || 7;
  const daysParam = Math.min(Math.max(parseInt(req.query.days) || 7, 1), 365);
  const rows = queryAll(
    `SELECT speed, recorded_at FROM locations
     WHERE user_id = ? AND speed > 0 AND recorded_at >= datetime('now', '-' || ? || ' days')
     ORDER BY recorded_at ASC`,
    [req.params.userId, daysParam]
  );

  if (rows.length < 5) {
    return res.json({ days, score: null, message: '数据不足，需要更多行驶记录' });
  }

  // 计算驾驶指标
  let totalPoints = rows.length;
  let speedingCount = 0;      // 超速（>120km/h = 33.3m/s）
  let hardBrakeCount = 0;     // 急刹（速度骤降 >15m/s → <5m/s）
  let highSpeedCount = 0;     // 高速行驶（>80km/h = 22.2m/s）
  let totalSpeed = 0;
  let maxSpeed = 0;

  for (let i = 0; i < rows.length; i++) {
    const spd = rows[i].speed || 0;
    totalSpeed += spd;
    if (spd > maxSpeed) maxSpeed = spd;

    if (spd > 33.3) speedingCount++;       // 超速 >120km/h
    if (spd > 22.2) highSpeedCount++;       // 高速 >80km/h

    // 急刹检测：当前 <5 且上一个 >15
    if (i > 0) {
      const prev = rows[i - 1].speed || 0;
      if (prev > 15 && spd < 5) hardBrakeCount++;
    }
  }

  const avgSpeed = totalSpeed / totalPoints;
  const speedingRate = speedingCount / totalPoints;   // 超速率
  const hardBrakeRate = hardBrakeCount / totalPoints; // 急刹率

  // 评分算法：基准100分，扣分项
  let score = 100;
  score -= speedingRate * 200;       // 超速率每1%扣2分
  score -= hardBrakeRate * 500;      // 急刹率每1%扣5分
  score -= Math.max(0, (avgSpeed - 15) * 1.5); // 平均速度过高扣分（>54km/h）
  score = Math.max(0, Math.min(100, Math.round(score)));

  // 评级
  let grade, gradeColor;
  if (score >= 90) { grade = 'A'; gradeColor = '#10B981'; }
  else if (score >= 75) { grade = 'B'; gradeColor = '#3B82F6'; }
  else if (score >= 60) { grade = 'C'; gradeColor = '#F59E0B'; }
  else { grade = 'D'; gradeColor = '#EF4444'; }

  res.json({
    days,
    score,
    grade,
    gradeColor,
    totalRecords: totalPoints,
    avgSpeedKmh: Math.round(avgSpeed * 3.6 * 10) / 10,
    maxSpeedKmh: Math.round(maxSpeed * 3.6 * 10) / 10,
    speedingCount,
    hardBrakeCount,
    highSpeedCount,
  });
});

// ==================== 逆编码缓存刷新 ====================

// 手动触发批量刷新（管理员API）：刷新超过30天的缓存条目
app.post('/api/admin/refresh-geocode-cache', requireAuth, async (req, res) => {
  const limit = parseInt(req.query.limit) || 500; // 每次最多刷新500条，防API超频
  // 查询过期条目（cached_at 超过30天 或 cached_at 为空）
  const expired = queryAll(
    `SELECT id, lat_key, lng_key FROM geocode_cache
     WHERE cached_at IS NULL OR cached_at < datetime('now', '-${CACHE_FRESH_DAYS} days')
     ORDER BY cached_at ASC LIMIT ?`, [limit]
  );
  if (expired.length === 0) {
    return res.json({ refreshed: 0, message: '没有需要刷新的缓存（90天内全部最新）' });
  }

  let refreshed = 0;
  let failed = 0;
  // 串行刷新，避免高德API限频（QPS约5-10）
  for (const item of expired) {
    try {
      const lat = parseFloat(item.lat_key);
      const lng = parseFloat(item.lng_key);
      const result = await reverseGeocode(lat, lng, { forceRefresh: true });
      if (result.address && !result.address.includes('位置(')) {
        refreshed++;
      } else {
        failed++;
      }
      // 高德API限频：每次间隔200ms
      await new Promise(r => setTimeout(r, 200));
    } catch (e) {
      failed++;
    }
  }

  res.json({
    refreshed,
    failed,
    total: expired.length,
    message: `刷新完成：${refreshed} 成功，${failed} 失败`,
  });
});

// 查看缓存统计（管理员API）
app.get('/api/admin/geocode-stats', (req, res) => {
  const total = queryOne('SELECT COUNT(*) as count FROM geocode_cache');
  // 新鲜：< 90天
  const fresh = queryOne(
    `SELECT COUNT(*) as count FROM geocode_cache
     WHERE cached_at >= datetime('now', '-${CACHE_FRESH_DAYS} days')`
  );
  // 需要刷新：>= 90天（90-180后台异步，>180同步刷新）
  const stale = queryOne(
    `SELECT COUNT(*) as count FROM geocode_cache
     WHERE cached_at IS NOT NULL AND cached_at >= datetime('now', '-${CACHE_STALE_DAYS} days')
       AND cached_at < datetime('now', '-${CACHE_FRESH_DAYS} days')`
  );
  const mustRefresh = queryOne(
    `SELECT COUNT(*) as count FROM geocode_cache
     WHERE cached_at IS NULL OR cached_at < datetime('now', '-${CACHE_STALE_DAYS} days')`
  );
  const oldest = queryOne(
    'SELECT cached_at FROM geocode_cache WHERE cached_at IS NOT NULL ORDER BY cached_at ASC LIMIT 1'
  );
  const newest = queryOne(
    'SELECT cached_at FROM geocode_cache WHERE cached_at IS NOT NULL ORDER BY cached_at DESC LIMIT 1'
  );
  res.json({
    totalEntries: total.count,
    freshEntries: fresh.count,       // <90天，直接可用
    staleEntries: stale.count,       // 90-180天，后台异步刷新
    expiredEntries: mustRefresh.count, // >180天，必须同步刷新
    freshDays: CACHE_FRESH_DAYS,
    staleDays: CACHE_STALE_DAYS,
    oldestCached: oldest?.cached_at || null,
    newestCached: newest?.cached_at || null,
  });
});

// 定时任务：每月1号凌晨3点自动批量刷新过期缓存
const GEOCODE_REFRESH_DAY = 1;   // 每月1号
const GEOCODE_REFRESH_HOUR = 3;  // 凌晨3点
const GEOCODE_REFRESH_LIMIT = 1000; // 自动刷新每次最多1000条

function _checkGeocodeRefreshSchedule() {
  const now = new Date();
  if (now.getDate() === GEOCODE_REFRESH_DAY && now.getHours() === GEOCODE_REFRESH_HOUR) {
    // 当天本轮是否已执行过（用简单标记防重复）
    const today = now.toISOString().split('T')[0];
    if (_lastRefreshDate === today) return;
    _lastRefreshDate = today;
    console.log(`[定时刷新] 开始刷新逆编码缓存（超过${CACHE_FRESH_DAYS}天的条目，每月${GEOCODE_REFRESH_DAY}日 ${GEOCODE_REFRESH_HOUR}:00）...`);
    _refreshGeocodeCacheBatch(GEOCODE_REFRESH_LIMIT);
  }
}
let _lastRefreshDate = '';

async function _refreshGeocodeCacheBatch(limit) {
  const expired = queryAll(
    `SELECT id, lat_key, lng_key FROM geocode_cache
     WHERE cached_at IS NULL OR cached_at < datetime('now', '-${CACHE_FRESH_DAYS} days')
     ORDER BY cached_at ASC LIMIT ?`, [limit]
  );
  if (expired.length === 0) {
    console.log('[定时刷新] 没有过期缓存');
    return;
  }
  console.log(`[定时刷新] 找到 ${expired.length} 条过期缓存，开始刷新...`);
  let ok = 0, fail = 0;
  for (const item of expired) {
    try {
      const lat = parseFloat(item.lat_key);
      const lng = parseFloat(item.lng_key);
      await reverseGeocode(lat, lng, { forceRefresh: true });
      ok++;
      await new Promise(r => setTimeout(r, 200)); // 限频
    } catch (e) {
      fail++;
    }
  }
  console.log(`[定时刷新] 完成：${ok} 成功，${fail} 失败`);
}

// 每小时检查一次是否到了刷新时间
setInterval(_checkGeocodeRefreshSchedule, 3600000);

// ==================== WebSocket ====================
const onlineUsers = new Map();

io.on('connection', (socket) => {
  console.log('用户连接:', socket.id);

  socket.on('user:online', (data) => {
    const { userId, token } = data;
    // 验证会话 token（如果提供了 token）
    if (token) {
      const tokenUserId = verifySession(token);
      if (!tokenUserId || tokenUserId !== userId) {
        // token 无效或不属于该用户，踢掉
        socket.emit('force_logout', { reason: '会话已过期，请重新登录' });
        socket.disconnect(true);
        return;
      }
    }
    const circles = queryAll('SELECT circle_id FROM circle_members WHERE user_id = ?', [userId]);
    const circleIds = circles.map(c => c.circle_id);
    onlineUsers.set(socket.id, { userId, circleIds, token: token || null });
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
      emitLat += (Math.random() - 0.5) * 0.01;
      emitLng += (Math.random() - 0.5) * 0.01;
    }

    // 逆地理解码（非阻塞：先写入缓存/坐标，后台异步更新地址）
    let address = '';
    const now = Date.now();
    const lastCall = _geocodeLastCall.get(userId) || 0;
    if (now - lastCall > GEOCODE_THROTTLE_MS) {
      // 距上次调用超过30秒，允许调API
      _geocodeLastCall.set(userId, now);
      const geoResult = await reverseGeocode(latitude, longitude);
      address = geoResult.address || geoResult.formatted || '';
      // Fallback: API返回空或降级为坐标字符串时，取用户最近有效地址
      if (!address || /^\d+\.\d+,\s*\d+\.\d+$/.test(address)) {
        const lastAddr = queryOne(
          "SELECT address FROM locations WHERE user_id = ? AND address IS NOT NULL AND address != '' AND address NOT GLOB '*[0-9].[0-9]*' ORDER BY recorded_at DESC LIMIT 1",
          [userId]
        );
        address = lastAddr?.address || address;
      }
      // 更新停留（用完整地址，不是formatted短地址）
      updateStay(userId, latitude, longitude, address, speed);
    } else {
      // 节流中，用缓存（3位≈110m，比2位更精确）
      const cached = queryOne('SELECT address, formatted FROM geocode_cache WHERE lat_key = ? AND lng_key = ?',
        [latitude.toFixed(3), longitude.toFixed(3)]);
      address = cached?.address || cached?.formatted || '';
      // Fallback: 缓存未命中时，取用户最近一条有地址的记录（绝不让address为空）
      if (!address) {
        const lastAddr = queryOne(
          "SELECT address FROM locations WHERE user_id = ? AND address IS NOT NULL AND address != '' ORDER BY recorded_at DESC LIMIT 1",
          [userId]
        );
        address = lastAddr?.address || '';
      }
      updateStay(userId, latitude, longitude, address, speed);
    }

    run('INSERT INTO locations (user_id, latitude, longitude, accuracy, battery_level, is_charging, speed, address) VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
      [userId, emitLat, emitLng, accuracy || null, batteryLevel != null ? batteryLevel : null, isCharging ? 1 : 0, speed || 0, address]);

    // 广播位置 + 停留信息
    const payload = { userId, latitude: emitLat, longitude: emitLng, accuracy, batteryLevel, isCharging, speed, address, timestamp: Date.now() };
    // 附带当前停留信息，让客户端实时更新停留时长
    const currentStay = queryOne('SELECT * FROM stays WHERE user_id = ? AND ended_at IS NULL ORDER BY started_at DESC LIMIT 1', [userId]);
    if (currentStay && !(speed > 1.0)) {
      payload.stay_address = currentStay.address;
      payload.stay_minutes = Math.round((Date.now() - new Date(currentStay.started_at + 'Z').getTime()) / 60000);
      payload.stay_started_at = new Date(currentStay.started_at + 'Z').toISOString();
    }

    // 幽灵模式：只发送给允许看到的圈子
    const user = queryOne('SELECT ghost_mode FROM users WHERE id = ?', [userId]);
    const ghostMode = user?.ghost_mode || 'off';
    // 模糊模式下在 payload 中标记，让客户端知道应该显示虚化圆圈
    if (ghostMode === 'blur') payload.ghostMode = 'blur';

    info.circleIds.forEach(cid => {
      if (ghostMode === 'invisible') return; // 完全隐身
      socket.to(cid).emit('member:location', payload);
      // 发送者也需要收到自己的位置（含地址），用于前端显示逆地理解码结果
      socket.emit('member:location', payload);
    });

    // 地理围栏检测
    // 策略：首次上线从 DB 读取上次状态到内存（1次查询），之后纯内存比对
    //       只有进入/离开时才写 1 次 DB，日常零 DB 开销
    if (!settings?.blur_location) { // 模糊模式下不触发围栏
      if (!socket.data) socket.data = {};

      // 首次位置上报：从 DB 加载上次状态到内存，然后 return（不触发通知）
      if (!socket.data._fenceLoaded) {
        socket.data._fenceLoaded = true;
        socket.data.insideFences = new Set();
        const states = queryAll('SELECT fence_id, is_inside FROM user_fence_states WHERE user_id = ?', [userId]);
        states.forEach(s => { if (s.is_inside === 1) socket.data.insideFences.add(s.fence_id); });
        return;
      }

      // 后续上报：纯内存比对
      info.circleIds.forEach(cid => {
        const fences = queryAll('SELECT * FROM geofences WHERE circle_id = ?', [cid]);
        fences.forEach(fence => {
          const dist = getDistance(latitude, longitude, fence.latitude, fence.longitude);
          const isNowInside = dist <= fence.radius;
          const wasInside = socket.data.insideFences.has(fence.id);

          if (isNowInside && !wasInside) {
            socket.data.insideFences.add(fence.id);
            run('INSERT OR REPLACE INTO user_fence_states (user_id, fence_id, is_inside, updated_at) VALUES (?, ?, 1, datetime("now"))',
              [userId, fence.id]);
            io.to(cid).emit('geofence:alert', {
              fenceName: fence.name, userId,
              userName: queryOne('SELECT name FROM users WHERE id = ?', [userId])?.name || '未知',
              action: 'entered', distance: Math.round(dist), timestamp: Date.now()
            });
          } else if (!isNowInside && wasInside) {
            socket.data.insideFences.delete(fence.id);
            run('INSERT OR REPLACE INTO user_fence_states (user_id, fence_id, is_inside, updated_at) VALUES (?, ?, 0, datetime("now"))',
              [userId, fence.id]);
            io.to(cid).emit('geofence:alert', {
              fenceName: fence.name, userId,
              userName: queryOne('SELECT name FROM users WHERE id = ?', [userId])?.name || '未知',
              action: 'left', distance: Math.round(dist), timestamp: Date.now()
            });
          }
        });
      });
    }

    // 4.6 到家/离家自动通知：自动从停留记录推断"家"位置（最常夜间停留点）
    if (!settings?.blur_location) {
      if (!socket.data) socket.data = {};
      if (!socket.data.homeZone) {
        // 首次加载：查询 stay_type='home' 的最近停留，取经纬度
        const homeStay = queryOne(
          `SELECT latitude, longitude FROM stays WHERE user_id = ? AND stay_type = 'home'
           ORDER BY started_at DESC LIMIT 1`, [userId]
        );
        if (homeStay) {
          socket.data.homeZone = { lat: homeStay.latitude, lng: homeStay.longitude, radius: 100 };
        }
      }
      if (socket.data.homeZone && !(speed > 3.0)) { // 移动中不触发到家/离家通知
        const hz = socket.data.homeZone;
        const distHome = getDistance(latitude, longitude, hz.lat, hz.lng);
        const wasHome = socket.data.wasAtHome || false;
        const isHome = distHome <= hz.radius;

        if (isHome && !wasHome) {
          // 到家通知
          socket.data.wasAtHome = true;
          const userName = queryOne('SELECT name FROM users WHERE id = ?', [userId])?.name || '未知';
          info.circleIds.forEach(cid => {
            io.to(cid).emit('home:status', {
              userId, userName, action: 'arrived', address,
              distance: Math.round(distHome), timestamp: Date.now()
            });
          });
        } else if (!isHome && wasHome) {
          // 离家通知
          socket.data.wasAtHome = false;
          const userName = queryOne('SELECT name FROM users WHERE id = ?', [userId])?.name || '未知';
          info.circleIds.forEach(cid => {
            io.to(cid).emit('home:status', {
              userId, userName, action: 'left', address,
              distance: Math.round(distHome), timestamp: Date.now()
            });
          });
        }
      }
    }

    // 碰撞检测：多重确认 + 降噪
    // 策略：
    // 0) 低精度GPS信号直接跳过（accuracy > 50米 = 速度不可信）
    // 1) 9点滑动窗口抑制GPS毛刺
    // 2) 超高速阈值 60m/s（216km/h），正常驾驶不可能达到
    // 3) 急刹检测：连续2次上报满足(prev>20, cur<3)才触发
    // 4) 两次上报间隔>30秒的prevSpeed丢弃，不用来比较
    // 5) 冷却期：触发后3分钟内不再重复触发
    // 注意：此处复用外层已定义的 now 变量（const now = Date.now()）
    const GPS_ACCURACY_THRESHOLD = 50; // 精度差于50米的GPS信号不参与碰撞检测
    if (accuracy != null && accuracy > GPS_ACCURACY_THRESHOLD) {
      // 低精度信号：仅记录状态，不参与碰撞判定
      if (!_collisionState.has(userId)) {
        _collisionState.set(userId, { speedWindow: [], suspiciousCount: 0, lastAlertTime: 0 });
      }
      const cs = _collisionState.get(userId);
      cs.suspiciousCount = 0; // 低精度信号重置可疑计数
      // 不更新 lastSpeed/lastTime，保持上次高精度的值用于后续比较
    } else if (speed != null) {
    if (!_collisionState.has(userId)) {
      _collisionState.set(userId, { speedWindow: [], suspiciousCount: 0, lastAlertTime: 0 });
    }
    const cs = _collisionState.get(userId);
    
    // 维护9点滑动窗口
    cs.speedWindow.push(speed);
    if (cs.speedWindow.length > 9) cs.speedWindow.shift();
    const avgSpeed = cs.speedWindow.reduce((a, b) => a + b, 0) / cs.speedWindow.length;
    
    // 冷却期内跳过检测（3分钟）
    if (now - cs.lastAlertTime < 180000) {
      cs.lastSpeed = speed;
      cs.lastTime = now;
      // 跳过碰撞检测，继续后面的逻辑
    } else {
      // 超高速检测：平均速度 > 60m/s ≈ 216km/h
      if (avgSpeed > 60) {
        cs.lastAlertTime = now;
        info.circleIds.forEach(cid => {
          io.to(cid).emit('collision:alert', {
            userId, userName: queryOne('SELECT name FROM users WHERE id = ?', [userId])?.name || '未知',
            latitude, longitude, speed, avgSpeed: Math.round(avgSpeed * 10) / 10,
            type: 'high_speed', timestamp: Date.now()
          });
        });
      }
      
      // 急刹检测：上次速度>20m/s，本次<3m/s，且间隔<30秒
      if (cs.lastSpeed != null && cs.lastTime != null) {
        const timeDiff = (now - cs.lastTime) / 1000;
        if (timeDiff > 0 && timeDiff <= 30) {
          if (cs.lastSpeed > 20 && avgSpeed < 3) {
            // 满足急刹特征，增加可疑计数
            cs.suspiciousCount = (cs.suspiciousCount || 0) + 1;
            if (cs.suspiciousCount >= 2) {
              // 连续2次确认，触发碰撞告警
              cs.lastAlertTime = now;
              cs.suspiciousCount = 0;
              info.circleIds.forEach(cid => {
                io.to(cid).emit('collision:alert', {
                  userId, userName: queryOne('SELECT name FROM users WHERE id = ?', [userId])?.name || '未知',
                  latitude, longitude, speed, prevSpeed: cs.lastSpeed, avgSpeed: Math.round(avgSpeed * 10) / 10,
                  type: 'hard_brake', timestamp: Date.now()
                });
              });
            }
          } else {
            // 不满足急刹特征，重置可疑计数
            cs.suspiciousCount = 0;
          }
        }
        // 间隔>30秒，之前的速度不再用于急刹比较
        if (timeDiff > 30) {
          cs.suspiciousCount = 0;
        }
      }
      
      cs.lastSpeed = avgSpeed; // 用平均速度而非瞬时速度
      cs.lastTime = now;
    }
    } // end of else (高精度信号才参与碰撞检测)
    // 低电量自动通知：电量<15%且未充广播通知（4.4新功能）
    if (batteryLevel != null && batteryLevel < 15 && !isCharging) {
      const lastLowBattery = _lowBatterySent.get(userId) || 0;
      if (now - lastLowBattery > 3600000) { // 每小时最多通知一次
        _lowBatterySent.set(userId, now);
        info.circleIds.forEach(cid => {
          io.to(cid).emit('battery:low', {
            userId, userName: queryOne('SELECT name FROM users WHERE id = ?', [userId])?.name || '未知',
            batteryLevel, timestamp: Date.now()
          });
        });
      }
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
  socket.on('interaction:care', (data) => {
    const info = onlineUsers.get(socket.id);
    if (!info) return;
    info.circleIds.forEach(cid => {
      io.to(cid).emit('interaction:care', {
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
  // 初始化认证模块
  initAuth(queryOne);
  cleanExpiredSessions(); // 数据库就绪后清理过期会话
  server.listen(PORT, () => {
    console.log(`\n  FamilyMap 位置共享服务已启动`);
    console.log(`  本地访问: http://localhost:${PORT}`);
    console.log(`  局域网: http://<IP>:${PORT}`);
    console.log(`  逆地理解码: ${AMAP_KEY ? '已配置高德Key' : '未配置(使用坐标降级)'}\n`);
  });
}).catch(err => { console.error('DB初始化失败:', err); process.exit(1); });
