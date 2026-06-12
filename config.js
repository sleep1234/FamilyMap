// ==================== FamilyMap 配置管理 ====================
// 所有配置集中管理，支持环境变量和默认值

const path = require('path');

module.exports = {
  // 服务器
  PORT: parseInt(process.env.PORT) || 3000,
  HOST: process.env.HOST || '0.0.0.0',

  // 数据库
  DB_PATH: process.env.DB_PATH || path.join(__dirname, 'familymap.db'),

  // 高德地图 API
  AMAP_KEY: process.env.AMAP_KEY || '',

  // 密码加密（必须设置，生产环境请使用随机强密码）
  PWD_SALT: process.env.PWD_SALT || 'FamilyMap2026Salt',

  // 会话
  SESSION_EXPIRE_DAYS: 7,

  // 逆地理缓存
  CACHE_FRESH_DAYS: 90,
  CACHE_STALE_DAYS: 180,
  GEOCODE_THROTTLE_MS: 30000,

  // 逆地理缓存定时刷新
  GEOCODE_REFRESH_DAY: 1,
  GEOCODE_REFRESH_HOUR: 3,
  GEOCODE_REFRESH_LIMIT: 1000,

  // 停留检测
  STAY_DRIFT_TOLERANCE: 200,     // 米
  STAY_SPEED_THRESHOLD: 3.0,     // m/s
  STAY_LEAVE_CONFIRM_COUNT: 2,
  STAY_TIMEOUT_HOURS: 24,

  // 碰撞检测
  GPS_ACCURACY_THRESHOLD: 50,    // 米
  COLLISION_HIGH_SPEED: 60,      // m/s (≈216km/h)
  COLLISION_HARD_BRAKE_THRESHOLD: 20,  // m/s
  COLLISION_COOLDOWN_MS: 180000, // 3分钟

  // 低电量通知
  LOW_BATTERY_THRESHOLD: 15,
  LOW_BATTERY_INTERVAL_MS: 3600000, // 1小时

  // 存活检测
  ALIVE_WARNING_HOURS: 24,

  // 分享链接
  SHARE_DEFAULT_DURATION_MINUTES: 60,
  SHARE_CLEANUP_INTERVAL_MS: 3600000, // 1小时
};
