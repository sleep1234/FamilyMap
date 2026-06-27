const config = require('../config');
const { queryOne, queryAll, run, getDistance, boundedSet } = require('../db');
const { notifyGeofence } = require('./bark');

let _io;

function init(io) {
  _io = io;
}

const _geofenceThrottle = new Map();

// 围栏连续确认次数（防止室内 GPS 跳变导致误报）
const CONFIRM_COUNT = 3;

function checkGeofence(userId, socket, latitude, longitude, circleIds) {
  const now = Date.now();
  const lastTime = _geofenceThrottle.get(userId) || 0;
  if (now - lastTime < config.GEOFENCE_THROTTLE_MS) return;
  boundedSet(_geofenceThrottle, userId, now);

  if (!socket.data) socket.data = {};

  if (!socket.data._fenceLoaded) {
    socket.data._fenceLoaded = true;
    socket.data.insideFences = new Set();
    socket.data._fenceConfirm = {}; // { fenceId: { inside: 0, outside: 0, confirmed: null } }
    const states = queryAll('SELECT fence_id, is_inside FROM user_fence_states WHERE user_id = ?', [userId]);
    states.forEach(s => {
      if (s.is_inside === 1) {
        socket.data.insideFences.add(s.fence_id);
        socket.data._fenceConfirm[s.fence_id] = { inside: CONFIRM_COUNT, outside: 0, confirmed: 'inside' };
      } else {
        socket.data._fenceConfirm[s.fence_id] = { inside: 0, outside: CONFIRM_COUNT, confirmed: 'outside' };
      }
    });
    return;
  }

  // 初始化连续确认状态（如果还没有的话）
  if (!socket.data._fenceConfirm) socket.data._fenceConfirm = {};

  circleIds.forEach(cid => {
    const fences = queryAll('SELECT * FROM geofences WHERE circle_id = ?', [cid]);
    fences.forEach(fence => {
      const dist = getDistance(latitude, longitude, fence.latitude, fence.longitude);
      const isNowInside = dist <= fence.radius;
      const wasInside = socket.data.insideFences.has(fence.id);

      // 初始化该围栏的连续确认状态
      if (!socket.data._fenceConfirm[fence.id]) {
        socket.data._fenceConfirm[fence.id] = { inside: 0, outside: 0, confirmed: wasInside ? 'inside' : 'outside' };
      }

      const confirm = socket.data._fenceConfirm[fence.id];

      // 更新连续确认计数
      if (isNowInside) {
        confirm.inside++;
        confirm.outside = 0;
      } else {
        confirm.outside++;
        confirm.inside = 0;
      }

      // 判断是否触发事件
      if (confirm.inside >= CONFIRM_COUNT && confirm.confirmed !== 'inside') {
        // 连续 N 次在围栏内，触发进入事件
        confirm.confirmed = 'inside';
        if (!wasInside) {
          socket.data.insideFences.add(fence.id);
          run('INSERT OR REPLACE INTO user_fence_states (user_id, fence_id, is_inside, updated_at) VALUES (?, ?, 1, datetime("now"))',
            [userId, fence.id]);
          const userName = queryOne('SELECT name FROM users WHERE id = ?', [userId])?.name || '未知';
          _io.to(cid).emit('geofence:alert', {
            fenceName: fence.name, userId,
            userName,
            action: 'entered', distance: Math.round(dist), timestamp: Date.now()
          });
          // Bark 推送地理围栏进入通知
          notifyGeofence(userId, [cid], userName, fence.name, 'entered');
        }
      } else if (confirm.outside >= CONFIRM_COUNT && confirm.confirmed !== 'outside') {
        // 连续 N 次在围栏外，触发离开事件
        confirm.confirmed = 'outside';
        if (wasInside) {
          socket.data.insideFences.delete(fence.id);
          run('INSERT OR REPLACE INTO user_fence_states (user_id, fence_id, is_inside, updated_at) VALUES (?, ?, 0, datetime("now"))',
            [userId, fence.id]);
          const userName = queryOne('SELECT name FROM users WHERE id = ?', [userId])?.name || '未知';
          _io.to(cid).emit('geofence:alert', {
            fenceName: fence.name, userId,
            userName,
            action: 'left', distance: Math.round(dist), timestamp: Date.now()
          });
          // Bark 推送地理围栏离开通知
          notifyGeofence(userId, [cid], userName, fence.name, 'left');
        }
      }
    });
  });
}

module.exports = { init, checkGeofence };
