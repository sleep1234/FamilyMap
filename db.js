const crypto = require('crypto');
const bcrypt = require('bcryptjs');
const Database = require('better-sqlite3');
const config = require('./config');

let db;

const DB_PATH = config.DB_PATH;

function escapeHtml(str) {
  if (!str) return '';
  return str.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;').replace(/'/g, '&#39;');
}

function escapeXml(str) {
  if (!str) return '';
  return str.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;').replace(/'/g, '&apos;');
}

function getDistance(lat1, lon1, lat2, lon2) {
  const R = 6371000;
  const dLat = (lat2 - lat1) * Math.PI / 180;
  const dLon = (lon2 - lon1) * Math.PI / 180;
  const a = Math.sin(dLat / 2) ** 2 + Math.cos(lat1 * Math.PI / 180) * Math.cos(lat2 * Math.PI / 180) * Math.sin(dLon / 2) ** 2;
  return R * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
}

function boundedSet(map, key, value) {
  if (!map.has(key) && map.size >= config.MEMORY_MAP_MAX_SIZE) {
    const firstKey = map.keys().next().value;
    map.delete(firstKey);
  }
  map.set(key, value);
}

async function initDB() {
  db = new Database(DB_PATH);
  db.pragma('journal_mode = WAL');
  db.pragma('synchronous = NORMAL');
  db.pragma('cache_size = -8000');

  db.exec(`CREATE TABLE IF NOT EXISTS users (
    id TEXT PRIMARY KEY, name TEXT NOT NULL, avatar_color TEXT DEFAULT '#4F46E5',
    mood TEXT DEFAULT '', is_sleeping INTEGER DEFAULT 0, ghost_mode TEXT DEFAULT 'off',
    username TEXT UNIQUE, password_hash TEXT,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP)`);
  db.exec(`CREATE TABLE IF NOT EXISTS circles (
    id TEXT PRIMARY KEY, name TEXT NOT NULL, invite_code TEXT UNIQUE NOT NULL,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP)`);
  db.exec(`CREATE TABLE IF NOT EXISTS circle_members (
    circle_id TEXT NOT NULL, user_id TEXT NOT NULL,
    joined_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (circle_id, user_id))`);
  db.exec(`CREATE TABLE IF NOT EXISTS locations (
    id INTEGER PRIMARY KEY AUTOINCREMENT, user_id TEXT NOT NULL,
    latitude REAL NOT NULL, longitude REAL NOT NULL, accuracy REAL,
    battery_level INTEGER, is_charging INTEGER DEFAULT 0, speed REAL DEFAULT 0,
    address TEXT, recorded_at DATETIME DEFAULT CURRENT_TIMESTAMP)`);
  db.exec(`CREATE TABLE IF NOT EXISTS geofences (
    id INTEGER PRIMARY KEY AUTOINCREMENT, circle_id TEXT NOT NULL,
    name TEXT NOT NULL, latitude REAL NOT NULL, longitude REAL NOT NULL,
    radius INTEGER DEFAULT 200, created_by TEXT NOT NULL,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP)`);
  db.exec(`CREATE TABLE IF NOT EXISTS user_fence_states (
    user_id TEXT NOT NULL, fence_id INTEGER NOT NULL,
    is_inside INTEGER DEFAULT 0,
    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (user_id, fence_id))`);
  db.exec(`CREATE TABLE IF NOT EXISTS stays (
    id INTEGER PRIMARY KEY AUTOINCREMENT, user_id TEXT NOT NULL,
    latitude REAL NOT NULL, longitude REAL NOT NULL, address TEXT,
    started_at DATETIME NOT NULL, ended_at DATETIME,
    duration_minutes INTEGER)`);
  db.exec(`CREATE TABLE IF NOT EXISTS messages (
    id INTEGER PRIMARY KEY AUTOINCREMENT, circle_id TEXT NOT NULL,
    user_id TEXT NOT NULL, type TEXT DEFAULT 'text', content TEXT NOT NULL,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP)`);
  db.exec(`CREATE TABLE IF NOT EXISTS sos_alerts (
    id INTEGER PRIMARY KEY AUTOINCREMENT, user_id TEXT NOT NULL,
    latitude REAL NOT NULL, longitude REAL NOT NULL, address TEXT,
    status TEXT DEFAULT 'active', created_at DATETIME DEFAULT CURRENT_TIMESTAMP)`);
  db.exec(`CREATE TABLE IF NOT EXISTS contacts (
    id INTEGER PRIMARY KEY AUTOINCREMENT, user_id TEXT NOT NULL,
    contact_id TEXT NOT NULL, type TEXT DEFAULT 'friend',
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP)`);
  db.exec(`CREATE TABLE IF NOT EXISTS footprints (
    id INTEGER PRIMARY KEY AUTOINCREMENT, user_id TEXT NOT NULL,
    name TEXT NOT NULL, latitude REAL NOT NULL, longitude REAL NOT NULL,
    category TEXT DEFAULT 'other', note TEXT DEFAULT '', created_at DATETIME DEFAULT CURRENT_TIMESTAMP)`);
  try {
    const cols = db.prepare("PRAGMA table_info(footprints)").all();
    if (!cols.some(c => c.name === 'note')) db.exec(`ALTER TABLE footprints ADD COLUMN note TEXT DEFAULT ''`);
  } catch (e) { /* 忽略迁移错误 */ }
  db.exec(`CREATE TABLE IF NOT EXISTS geocode_cache (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    lat_key TEXT NOT NULL, lng_key TEXT NOT NULL,
    address TEXT NOT NULL, formatted TEXT,
    cached_at DATETIME DEFAULT CURRENT_TIMESTAMP)`);
  db.exec(`CREATE TABLE IF NOT EXISTS user_settings (
    user_id TEXT PRIMARY KEY,
    blur_location INTEGER DEFAULT 0,
    share_paused INTEGER DEFAULT 0,
    trail_skin TEXT DEFAULT 'default',
    nickname_color TEXT DEFAULT '',
    dark_mode INTEGER DEFAULT 0,
    lang TEXT DEFAULT 'zh',
    bark_key TEXT DEFAULT '')`);
  try {
    const cols = db.prepare("PRAGMA table_info(user_settings)").all();
    if (!cols.some(c => c.name === 'bark_key')) db.exec(`ALTER TABLE user_settings ADD COLUMN bark_key TEXT DEFAULT ''`);
  } catch (e) { /* 忽略迁移错误 */ }
  db.exec(`CREATE TABLE IF NOT EXISTS emergency_contacts (
    id INTEGER PRIMARY KEY AUTOINCREMENT, user_id TEXT NOT NULL,
    name TEXT NOT NULL, phone TEXT NOT NULL, relation TEXT DEFAULT 'family',
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP)`);
  db.exec(`CREATE TABLE IF NOT EXISTS sessions (
    token TEXT PRIMARY KEY,
    user_id TEXT NOT NULL,
    device_info TEXT DEFAULT '',
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    last_active DATETIME DEFAULT CURRENT_TIMESTAMP)`);
  db.exec(`CREATE TABLE IF NOT EXISTS share_tokens (
    token TEXT PRIMARY KEY,
    user_id TEXT NOT NULL,
    latitude REAL NOT NULL,
    longitude REAL NOT NULL,
    expires_at INTEGER NOT NULL,
    track_mode INTEGER DEFAULT 0,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP)`);

  db.exec('CREATE INDEX IF NOT EXISTS idx_loc_user_time ON locations(user_id, recorded_at DESC)');
  db.exec('CREATE INDEX IF NOT EXISTS idx_loc_time ON locations(recorded_at DESC)');
  db.exec('CREATE INDEX IF NOT EXISTS idx_msg_circle_time ON messages(circle_id, created_at ASC)');
  db.exec('CREATE INDEX IF NOT EXISTS idx_stay_user ON stays(user_id, started_at DESC)');
  db.exec('CREATE INDEX IF NOT EXISTS idx_stay_user_end ON stays(user_id, ended_at)');
  db.exec('CREATE INDEX IF NOT EXISTS idx_geocode ON geocode_cache(lat_key, lng_key)');
  db.exec('CREATE INDEX IF NOT EXISTS idx_fence_circle ON geofences(circle_id)');
  db.exec('CREATE INDEX IF NOT EXISTS idx_circle_member_user ON circle_members(user_id)');
  db.exec('CREATE INDEX IF NOT EXISTS idx_circle_member_circle ON circle_members(circle_id)');
  db.exec('CREATE INDEX IF NOT EXISTS idx_sos_status ON sos_alerts(status)');
  db.exec('CREATE INDEX IF NOT EXISTS idx_sessions_user ON sessions(user_id)');
  db.exec('CREATE INDEX IF NOT EXISTS idx_sessions_token ON sessions(token)');
  db.exec('CREATE INDEX IF NOT EXISTS idx_share_tokens_user ON share_tokens(user_id)');
  db.exec('CREATE INDEX IF NOT EXISTS idx_share_tokens_expires ON share_tokens(expires_at)');

  try {
    const cols = db.prepare("PRAGMA table_info(users)").all().map(c => c.name);
    if (!cols.includes('username')) { db.exec('ALTER TABLE users ADD COLUMN username TEXT'); }
    if (!cols.includes('password_hash')) { db.exec('ALTER TABLE users ADD COLUMN password_hash TEXT'); }
    if (!cols.includes('avatar_url')) { db.exec('ALTER TABLE users ADD COLUMN avatar_url TEXT'); }
  } catch (e) { console.log('迁移提示:', e.message); }
  try { db.exec('CREATE INDEX IF NOT EXISTS idx_users_username ON users(username)'); } catch (e) { }

  try {
    const stayCols = db.prepare("PRAGMA table_info(stays)").all().map(c => c.name);
    if (!stayCols.includes('stay_type')) { db.exec("ALTER TABLE stays ADD COLUMN stay_type TEXT DEFAULT 'other'"); }
  } catch (e) { console.log('stays迁移提示:', e.message); }

  cleanExpiredShareTokens();
}

function queryAll(sql, params = []) {
  return db.prepare(sql).all(params);
}

function queryOne(sql, params = []) {
  return db.prepare(sql).get(params) || null;
}

function run(sql, params = []) {
  db.prepare(sql).run(params);
}

// better-sqlite3 写入即时持久化，无需手动保存
function saveDB() {}
function forceSaveDB() {}

process.on('SIGINT', () => { if (db) db.close(); process.exit(0); });
process.on('SIGTERM', () => { if (db) db.close(); process.exit(0); });

async function hashPassword(password) {
  return bcrypt.hash(password, config.BCRYPT_ROUNDS);
}

async function verifyPassword(password, hash) {
  return bcrypt.compare(password, hash);
}

function generateSessionToken() {
  return crypto.randomBytes(32).toString('hex');
}

let _sessionKickCallback = null;

function setSessionKickCallback(cb) {
  _sessionKickCallback = cb;
}

function createSession(userId, deviceInfo = '') {
  const token = generateSessionToken();
  const oldSessions = queryAll('SELECT token FROM sessions WHERE user_id = ?', [userId]);
  run('DELETE FROM sessions WHERE user_id = ?', [userId]);
  run('INSERT INTO sessions (token, user_id, device_info) VALUES (?, ?, ?)', [token, userId, deviceInfo]);
  if (_sessionKickCallback && oldSessions.length > 0) {
    _sessionKickCallback(userId, oldSessions.map(s => s.token));
  }
  return token;
}

function verifySession(token) {
  if (!token) return null;
  const session = queryOne('SELECT user_id FROM sessions WHERE token = ?', [token]);
  if (!session) return null;
  const maxAge = queryOne("SELECT created_at FROM sessions WHERE token = ? AND created_at < datetime('now', '-7 days')", [token]);
  if (maxAge) { run('DELETE FROM sessions WHERE token = ?', [token]); return null; }
  run("UPDATE sessions SET last_active = datetime('now') WHERE token = ?", [token]);
  return session.user_id;
}

function cleanExpiredSessions() {
  run("DELETE FROM sessions WHERE last_active < datetime('now', '-7 days')");
}

function cleanExpiredShareTokens() {
  run('DELETE FROM share_tokens WHERE expires_at < ?', [Date.now()]);
}

function cleanOldData() {
  try {
    run("DELETE FROM locations WHERE recorded_at < datetime('now', '-7 days')");
    run("DELETE FROM stays WHERE ended_at IS NOT NULL AND ended_at < datetime('now', '-90 days')");
    run("DELETE FROM messages WHERE created_at < datetime('now', '-30 days')");
    run("DELETE FROM geocode_cache WHERE cached_at < datetime('now', '-180 days')");
    run("DELETE FROM sos_alerts WHERE created_at < datetime('now', '-30 days')");
    db.exec('VACUUM');
    console.log('[DB] 已清理过期数据');
  } catch (e) {
    console.error('[DB] 清理过期数据失败:', e.message);
  }
}

function startCleanupSchedule() {
  const now = new Date();
  const next = new Date(now);
  next.setHours(3, 0, 0, 0);
  if (next <= now) next.setDate(next.getDate() + 1);
  const delay = next.getTime() - now.getTime();
  
  setTimeout(() => {
    cleanOldData();
    setInterval(cleanOldData, 6 * 60 * 60 * 1000);
  }, delay);
}

function getDbInstance() { return db; }

module.exports = {
  initDB, saveDB, forceSaveDB, queryAll, queryOne, run,
  hashPassword, verifyPassword,
  generateSessionToken, createSession, verifySession,
  cleanExpiredSessions, cleanExpiredShareTokens, cleanOldData, startCleanupSchedule,
  setSessionKickCallback, getDbInstance,
  escapeHtml, escapeXml, getDistance, boundedSet,
};
