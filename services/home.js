const config = require('../config');
const { queryOne, getDistance } = require('../db');
const { notifyHomeStatus } = require('./bark');

let _io;

function init(io) {
  _io = io;
}

// home 连续确认次数（防止室内 GPS 跳变导致误报）
const CONFIRM_COUNT = 3;

function checkHome(userId, socket, latitude, longitude, address, speed, circleIds) {
  if (speed > config.STAY_SPEED_THRESHOLD) return;

  if (!socket.data) socket.data = {};
  if (!socket.data.homeZone) {
    const homeStay = queryOne(
      `SELECT latitude, longitude FROM stays WHERE user_id = ? AND stay_type = 'home'
       ORDER BY started_at DESC LIMIT 1`, [userId]
    );
    if (homeStay) {
      socket.data.homeZone = { lat: homeStay.latitude, lng: homeStay.longitude, radius: 100 };
    }
  }

  if (socket.data.homeZone) {
    const hz = socket.data.homeZone;
    const distHome = getDistance(latitude, longitude, hz.lat, hz.lng);
    const isHome = distHome <= hz.radius;

    // 初始化连续确认状态
    if (!socket.data._homeConfirm) {
      const wasHome = socket.data.wasAtHome || false;
      socket.data._homeConfirm = {
        inside: wasHome ? CONFIRM_COUNT : 0,
        outside: wasHome ? 0 : CONFIRM_COUNT,
        confirmed: wasHome ? 'inside' : 'outside'
      };
    }

    const confirm = socket.data._homeConfirm;

    // 更新连续确认计数
    if (isHome) {
      confirm.inside++;
      confirm.outside = 0;
    } else {
      confirm.outside++;
      confirm.inside = 0;
    }

    // 判断是否触发事件
    if (confirm.inside >= CONFIRM_COUNT && confirm.confirmed !== 'inside') {
      // 连续 N 次在 home 范围内，触发到家事件
      confirm.confirmed = 'inside';
      if (!socket.data.wasAtHome) {
        socket.data.wasAtHome = true;
        const userName = queryOne('SELECT name FROM users WHERE id = ?', [userId])?.name || '未知';
        circleIds.forEach(cid => {
          _io.to(cid).emit('home:status', {
            userId, userName, action: 'arrived', address,
            distance: Math.round(distHome), timestamp: Date.now()
          });
        });
        // Bark 推送到家通知
        notifyHomeStatus(userId, circleIds, userName, 'arrived', address, Math.round(distHome));
      }
    } else if (confirm.outside >= CONFIRM_COUNT && confirm.confirmed !== 'outside') {
      // 连续 N 次在 home 范围外，触发离家事件
      confirm.confirmed = 'outside';
      if (socket.data.wasAtHome) {
        socket.data.wasAtHome = false;
        const userName = queryOne('SELECT name FROM users WHERE id = ?', [userId])?.name || '未知';
        circleIds.forEach(cid => {
          _io.to(cid).emit('home:status', {
            userId, userName, action: 'left', address,
            distance: Math.round(distHome), timestamp: Date.now()
          });
        });
        // Bark 推送离家通知
        notifyHomeStatus(userId, circleIds, userName, 'left', address, Math.round(distHome));
      }
    }
  }
}

module.exports = { init, checkHome };
