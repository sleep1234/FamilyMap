const config = require('../config');
const { queryOne, queryAll, run, getDistance, boundedSet } = require('../db');
const { notifyTripReport, notifyHomeStatus } = require('./bark');

let _io;
let _onlineUsers;

function init(io, onlineUsers) {
  _io = io;
  _onlineUsers = onlineUsers;
}

const _leaveConfirm = new Map();
const _stayThrottle = new Map();

function inferStayType(address) {
  if (!address) return 'other';
  if (/小区|公寓|花园|家园|大厦/.test(address)) return 'home';
  if (/公司|科技|大厦|园区|写字楼/.test(address)) return 'work';
  if (/学校|大学|学院|中学|小学/.test(address)) return 'school';
  if (/餐厅|饭店|美食|火锅|面馆|小吃/.test(address)) return 'food';
  if (/商场|购物|超市|影院|KTV|娱乐/.test(address)) return 'fun';
  if (/医院|诊所|卫生院/.test(address)) return 'hospital';
  return 'other';
}

function updateStay(userId, lat, lng, address, speed) {
  const now = Date.now();
  const lastTime = _stayThrottle.get(userId) || 0;
  if (now - lastTime < config.STAY_THROTTLE_MS) return;
  boundedSet(_stayThrottle, userId, now);

  speed = speed || 0;
  const isMoving = speed > config.STAY_SPEED_THRESHOLD;

  const active = queryOne('SELECT * FROM stays WHERE user_id = ? AND ended_at IS NULL ORDER BY started_at DESC LIMIT 1', [userId]);

  if (active) {
    const dist = getDistance(lat, lng, active.latitude, active.longitude);
    if (dist < config.STAY_DRIFT_TOLERANCE) {
      _leaveConfirm.delete(userId);
      return;
    } else {
      if (isMoving) return;
      const lc = _leaveConfirm.get(userId) || { count: 0, lat: 0, lng: 0 };
      const confirmDist = getDistance(lat, lng, lc.lat, lc.lng);
      if (lc.count > 0 && confirmDist < config.STAY_DRIFT_TOLERANCE) {
        _leaveConfirm.delete(userId);
      } else {
        boundedSet(_leaveConfirm, userId, { count: 1, lat, lng });
        return;
      }
      const started = new Date(active.started_at + 'Z');
      const ended = new Date();
      const dur = Math.round((ended - started) / 60000);
      const stayType = inferStayType(active.address || address || '');
      run('UPDATE stays SET ended_at = datetime("now"), duration_minutes = ?, stay_type = ? WHERE id = ?', [dur, stayType, active.id]);

      // 停留时长不足阈值时不发通知（避免路口等红灯误报）
      if (dur >= (config.STAY_NOTIFY_MIN_DURATION || 10)) {
        const user = queryOne('SELECT name FROM users WHERE id = ?', [userId]);
        const info = [..._onlineUsers.values()].find(i => i.userId === userId);
        const circleIds = info ? info.circleIds : [];
        if (info) {
          info.circleIds.forEach(cid => {
            _io.to(cid).emit('trip:report', {
              userId, userName: user?.name || '未知',
              action: 'left', address: active.address || '某地',
              duration: dur, stayType, timestamp: Date.now()
            });
          });
        }
        // Bark 推送停留/离开通知
        notifyTripReport(userId, circleIds, user?.name || '未知', 'left', active.address || '某地', dur, stayType);
      }

      if (stayType === 'home' && dur >= (config.STAY_NOTIFY_MIN_DURATION || 10)) {
        const homeDist = getDistance(lat, lng, active.latitude, active.longitude);
        if (homeDist > config.STAY_DRIFT_TOLERANCE) {
          const homeInfo = [..._onlineUsers.values()].find(i => i.userId === userId);
          const homeCircleIds = homeInfo ? homeInfo.circleIds : [];
          if (homeInfo) {
            homeInfo.circleIds.forEach(cid => {
              _io.to(cid).emit('home:status', {
                userId, userName: user?.name || '未知', action: 'left', address: active.address,
                distance: Math.round(homeDist), timestamp: Date.now()
              });
            });
          }
          // Bark 推送离家通知
          notifyHomeStatus(userId, homeCircleIds, user?.name || '未知', 'left', active.address, Math.round(homeDist));
        }
      }
    }
  }

  if (isMoving) return;

  const recent = queryOne(
    `SELECT * FROM stays WHERE user_id = ? AND ended_at IS NOT NULL AND ended_at >= datetime("now", "-2 hours") ORDER BY ended_at DESC LIMIT 1`,
    [userId]
  );

  if (recent) {
    const dist = getDistance(lat, lng, recent.latitude, recent.longitude);
    const endedAt = new Date(recent.ended_at + 'Z');
    const elapsedMinutes = (Date.now() - endedAt.getTime()) / 60000;
    const maxDist = elapsedMinutes < 30 ? config.STAY_DRIFT_TOLERANCE : 100;
    if (dist < maxDist) {
      run('INSERT INTO stays (user_id, latitude, longitude, address, stay_type, started_at) VALUES (?, ?, ?, ?, ?, datetime("now"))',
        [userId, recent.latitude, recent.longitude, recent.address || address || '', recent.stay_type || inferStayType(recent.address || address || '')]);
      return;
    }
  }

  const stayType = inferStayType(address || '');
  run('INSERT INTO stays (user_id, latitude, longitude, address, stay_type, started_at) VALUES (?, ?, ?, ?, ?, datetime("now"))',
    [userId, lat, lng, address || '', stayType]);
}

function startStayTimeoutCleanup() {
  setInterval(() => {
    try {
      const stale = queryAll('SELECT * FROM stays WHERE ended_at IS NULL AND started_at < datetime("now", "-24 hours")');
      stale.forEach(s => {
        const dur = Math.round((Date.now() - new Date(s.started_at + 'Z').getTime()) / 60000);
        run('UPDATE stays SET ended_at = datetime("now"), duration_minutes = ? WHERE id = ?', [dur, s.id]);
      });
    } catch (_) { }
  }, 300000);
}

module.exports = { init, updateStay, inferStayType, startStayTimeoutCleanup };
