const config = require('../config');
const { queryOne, boundedSet } = require('../db');
const { notifyCollision } = require('./bark');

let _io;
let _onlineUsers;

function init(io, onlineUsers) {
  _io = io;
  _onlineUsers = onlineUsers;
}

const _collisionState = new Map();
const _collisionThrottle = new Map();

function checkCollision(userId, latitude, longitude, speed, accuracy, now) {
  const throttleLast = _collisionThrottle.get(userId) || 0;
  if (now - throttleLast < config.DETECTION_THROTTLE_MS) return;
  boundedSet(_collisionThrottle, userId, now);

  const entry = _collisionState.get(userId);
  if (entry) {
    if (Date.now() - entry.ts > 86400000) {
      _collisionState.delete(userId);
    }
  }

  const info = [..._onlineUsers.values()].find(i => i.userId === userId);
  if (!info) return;

  const GPS_ACCURACY_THRESHOLD = config.GPS_ACCURACY_THRESHOLD;

  if (accuracy != null && accuracy > GPS_ACCURACY_THRESHOLD) {
    if (!_collisionState.has(userId)) {
      boundedSet(_collisionState, userId, { speedWindow: [], suspiciousCount: 0, lastAlertTime: 0, ts: Date.now() });
    }
    const cs = _collisionState.get(userId);
    cs.suspiciousCount = 0;
    cs.ts = Date.now();
    return;
  } else if (speed != null) {
    if (!_collisionState.has(userId)) {
      boundedSet(_collisionState, userId, { speedWindow: [], suspiciousCount: 0, lastAlertTime: 0, ts: Date.now() });
    }
    const cs = _collisionState.get(userId);
    cs.ts = Date.now();

    cs.speedWindow.push(speed);
    if (cs.speedWindow.length > 9) cs.speedWindow.shift();
    const avgSpeed = cs.speedWindow.reduce((a, b) => a + b, 0) / cs.speedWindow.length;

    if (now - cs.lastAlertTime < config.COLLISION_COOLDOWN_MS) {
      cs.lastSpeed = speed;
      cs.lastTime = now;
    } else {
      if (avgSpeed > config.COLLISION_HIGH_SPEED) {
        cs.lastAlertTime = now;
        const userName = queryOne('SELECT name FROM users WHERE id = ?', [userId])?.name || '未知';
        info.circleIds.forEach(cid => {
          _io.to(cid).emit('collision:alert', {
            userId, userName,
            latitude, longitude, speed, avgSpeed: Math.round(avgSpeed * 10) / 10,
            type: 'high_speed', timestamp: Date.now()
          });
        });
        // Bark 推送高速靠近通知
        notifyCollision(userId, info.circleIds, userName, avgSpeed);
      }

      if (cs.lastSpeed != null && cs.lastTime != null) {
        const timeDiff = (now - cs.lastTime) / 1000;
        if (timeDiff > 0 && timeDiff <= 30) {
          if (cs.lastSpeed > config.COLLISION_HARD_BRAKE_THRESHOLD && avgSpeed < 3) {
            cs.suspiciousCount = (cs.suspiciousCount || 0) + 1;
            if (cs.suspiciousCount >= 2) {
              cs.lastAlertTime = now;
              cs.suspiciousCount = 0;
              info.circleIds.forEach(cid => {
                _io.to(cid).emit('collision:alert', {
                  userId, userName: queryOne('SELECT name FROM users WHERE id = ?', [userId])?.name || '未知',
                  latitude, longitude, speed, prevSpeed: cs.lastSpeed, avgSpeed: Math.round(avgSpeed * 10) / 10,
                  type: 'hard_brake', timestamp: Date.now()
                });
              });
            }
          } else {
            cs.suspiciousCount = 0;
          }
        }
        if (timeDiff > 30) {
          cs.suspiciousCount = 0;
        }
      }

      cs.lastSpeed = avgSpeed;
      cs.lastTime = now;
    }
  }
}

module.exports = { init, checkCollision };
