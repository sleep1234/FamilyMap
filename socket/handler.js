const config = require('../config');
const { queryOne, queryAll, run, verifySession, boundedSet } = require('../db');
const { reverseGeocode, setGeocodeThrottle, getGeocodeLastCall } = require('../services/geocode');
const { updateStay } = require('../services/stay');
const { checkCollision } = require('../services/collision');
const { checkGeofence } = require('../services/geofence');
const { checkHome } = require('../services/home');
const { notifyLowBattery, notifyAliveWarning, notifyCare, notifyEmojiBomb } = require('../services/bark');

let _io = null;  // Module-level reference to socket.io instance

const onlineUsers = new Map();

const _lowBatterySent = new Map();

function registerSocketHandlers(io) {
  _io = io;
  io.use((socket, next) => {
    const token = socket.handshake.auth.token || socket.handshake.query.token;
    if (!token) return next(new Error('Authentication required'));
    const userId = verifySession(token);
    if (!userId) return next(new Error('Invalid or expired token'));
    socket.data.userId = userId;
    socket.data.token = token;
    next();
  });

  const stayService = require('../services/stay');
  stayService.init(io, onlineUsers);

  const collisionService = require('../services/collision');
  collisionService.init(io, onlineUsers);

  const geofenceService = require('../services/geofence');
  geofenceService.init(io);

  const homeService = require('../services/home');
  homeService.init(io);

  io.on('connection', (socket) => {
    if (!socket.data.userId) {
      socket.disconnect(true);
      return;
    }
    console.log('用户连接:', socket.id, 'userId:', socket.data.userId);

    const socketThrottle = new Map();

    function checkEventThrottle(eventName) {
      const last = socketThrottle.get(eventName) || 0;
      // location:update 不走全局限流——位置更新有客户端自适应频率控制
      // 服务端只需防止单毫秒内的恶意刷量（如补传缓存），500ms 足够
      const limit = eventName === 'location:update' ? 500 : config.SOCKET_EVENT_THROTTLE_MS;
      if (Date.now() - last < limit) return false;
      socketThrottle.set(eventName, Date.now());
      return true;
    }

    socket.on('user:online', (data) => {
      if (!socket.data.userId) return;
      const { userId } = data;
      if (userId !== socket.data.userId) {
        socket.emit('force_logout', { reason: '用户身份不匹配' });
        socket.disconnect(true);
        return;
      }
      const circles = queryAll('SELECT circle_id FROM circle_members WHERE user_id = ?', [userId]);
      const circleIds = circles.map(c => c.circle_id);
      onlineUsers.set(socket.id, { userId, circleIds, token: socket.data.token });
      circleIds.forEach(cid => socket.join(cid));
      circleIds.forEach(cid => socket.to(cid).emit('member:online', { userId, timestamp: Date.now() }));
      console.log(`[上线] socket=${socket.id}, userId=${userId}, circles=${circleIds.length}, joined=${circleIds.join(',')}`);
    });

    socket.on('location:update', async (data) => {
      if (!socket.data.userId) return;
      if (!checkEventThrottle('location:update')) {
        console.log(`[位置限流] userId=${socket.data.userId}`);
        return;
      }

      // 安全修复：userId 从 socket 鉴权中取，不允许客户端伪造
      const userId = socket.data.userId;
      const { latitude, longitude, accuracy, batteryLevel, isCharging, speed } = data;

      if (typeof latitude !== 'number' || typeof longitude !== 'number') return;
      if (latitude < -90 || latitude > 90 || longitude < -180 || longitude > 180) return;
      if (speed != null && (typeof speed !== 'number' || speed < 0)) return;

      const info = onlineUsers.get(socket.id);
      if (!info) {
        console.log(`[位置丢失] info为空: userId=${userId}, socketId=${socket.id}, onlineUsers数=${onlineUsers.size}`);
        return;
      }

      // 合并查询：一次获取用户设置、幽灵模式、用户名
      const userInfo = queryOne(`
        SELECT u.ghost_mode, u.name, 
               us.blur_location, us.share_paused
        FROM users u 
        LEFT JOIN user_settings us ON u.id = us.user_id 
        WHERE u.id = ?
      `, [userId]);
      
      if (userInfo?.share_paused) return;

      let emitLat = latitude, emitLng = longitude;
      if (userInfo?.blur_location) {
        emitLat += (Math.random() - 0.5) * 0.01;
        emitLng += (Math.random() - 0.5) * 0.01;
      }

      let address = '';
      const now = Date.now();
      const lastCall = getGeocodeLastCall(userId);
      if (now - lastCall > config.GEOCODE_THROTTLE_MS) {
        setGeocodeThrottle(userId, now);
        const geoResult = await reverseGeocode(latitude, longitude);
        address = geoResult.address || geoResult.formatted || '';
        if (!address || /^\d+\.\d+,\s*\d+\.\d+$/.test(address)) {
          const lastAddr = queryOne(
            "SELECT address FROM locations WHERE user_id = ? AND address IS NOT NULL AND address != '' AND address NOT GLOB '*[0-9].[0-9]*' ORDER BY recorded_at DESC LIMIT 1",
            [userId]
          );
          address = lastAddr?.address || address;
        }
        updateStay(userId, latitude, longitude, address, speed);
      } else {
        const cached = queryOne('SELECT address, formatted FROM geocode_cache WHERE lat_key = ? AND lng_key = ?',
          [latitude.toFixed(3), longitude.toFixed(3)]);
        address = cached?.address || cached?.formatted || '';
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

      // 位置更新日志（每30秒内同用户只打印一次，防刷屏）
      const logKey = `locLog_${userId}`;
      const logNow = Date.now();
      if (!socketThrottle.get(logKey) || logNow - socketThrottle.get(logKey) > 30000) {
        socketThrottle.set(logKey, logNow);
        console.log(`[位置更新] userId=${userId}, lat=${latitude.toFixed(5)}, lng=${longitude.toFixed(5)}, speed=${(speed||0).toFixed(1)}m/s, acc=${accuracy?.toFixed(0)||'?'}m`);
      }

      const payload = { userId, latitude: emitLat, longitude: emitLng, accuracy, batteryLevel, isCharging, speed, address, timestamp: Date.now() };
      // 携带拖尾皮肤设置
      if (userInfo?.trail_skin && userInfo.trail_skin !== 'default') {
        payload.trailSkin = userInfo.trail_skin;
      }
      const currentStay = queryOne('SELECT * FROM stays WHERE user_id = ? AND ended_at IS NULL ORDER BY started_at DESC LIMIT 1', [userId]);
      if (currentStay && !(speed > 1.0)) {
        payload.stay_address = currentStay.address;
        payload.stay_minutes = Math.round((Date.now() - new Date(currentStay.started_at + 'Z').getTime()) / 60000);
        payload.stay_started_at = new Date(currentStay.started_at + 'Z').toISOString();
      }

      const ghostMode = userInfo?.ghost_mode || 'off';
      if (ghostMode === 'blur') payload.ghostMode = 'blur';

      // DEBUG: 诊断位置分发
      const roomSockets = info.circleIds.length > 0 ? io.sockets.adapter.rooms.get(info.circleIds[0]) : null;
      const roomSize = roomSockets ? roomSockets.size : 0;
      console.log(`[位置分发] userId=${userId}, circles=${info.circleIds.length}, ghostMode=${ghostMode}, roomSize=${roomSize}, payload.accuracy=${accuracy}`);

      info.circleIds.forEach(cid => {
        if (ghostMode === 'invisible') return;
        socket.to(cid).emit('member:location', payload);
        socket.emit('member:location', payload);
      });

      if (!userInfo?.blur_location) {
        checkGeofence(userId, socket, latitude, longitude, info.circleIds);

        checkHome(userId, socket, latitude, longitude, address, speed, info.circleIds);

        checkCollision(userId, latitude, longitude, speed, accuracy, now);
      }

      if (batteryLevel != null && batteryLevel < config.LOW_BATTERY_THRESHOLD && !isCharging) {
        const lastLowBattery = _lowBatterySent.get(userId) || 0;
        if (now - lastLowBattery > config.LOW_BATTERY_INTERVAL_MS) {
          boundedSet(_lowBatterySent, userId, now);
          const userName = userInfo?.name || '未知';
          info.circleIds.forEach(cid => {
            io.to(cid).emit('battery:low', {
              userId, userName, batteryLevel, timestamp: Date.now()
            });
          });
          // Bark 推送低电量通知
          notifyLowBattery(userId, info.circleIds, userName, batteryLevel);
        }
      }
    });

    socket.on('emoji:bomb', (data) => {
      if (!socket.data.userId) return;
      if (!checkEventThrottle('emoji:bomb')) return;
      const info = onlineUsers.get(socket.id);
      if (!info) return;
      // 安全修复：userId 从 socket 鉴权中取
      const userId = socket.data.userId;
      info.circleIds.forEach(cid => {
        socket.to(cid).emit('emoji:bomb', {
          userId: userId,
          emoji: data.emoji || '❤️',
          count: data.count || 10,
          timestamp: Date.now()
        });
      });
      // Bark 推送 emoji 炸弹通知
      const emojiUser = queryOne('SELECT name FROM users WHERE id = ?', [userId]);
      notifyEmojiBomb(userId, info.circleIds, emojiUser?.name || '某人', data.emoji || '❤️');
    });

    socket.on('interaction:care', (data) => {
      if (!socket.data.userId) return;
      if (!checkEventThrottle('interaction:care')) return;
      const info = onlineUsers.get(socket.id);
      if (!info) return;
      // 安全修复：userId 从 socket 鉴权中取
      const userId = socket.data.userId;
      const user = queryOne('SELECT avatar_url, name FROM users WHERE id = ?', [userId]);
      const targetUserId = data.targetUserId;
      
      if (targetUserId) {
        // 定向推送：只推送给目标用户
        // 找到目标用户的 socket
        for (const [sid, memberInfo] of onlineUsers.entries()) {
          if (memberInfo.userId === targetUserId) {
            socket.to(sid).emit('interaction:care', {
              fromUserId: userId,
              fromUserName: user?.name || '某人',
              fromUserAvatarUrl: user?.avatar_url || null,
              timestamp: Date.now()
            });
            break;
          }
        }
        // Bark 推送给目标用户（如果离线）
        notifyCare(userId, [targetUserId], user?.name || '某人');
      } else {
        // 兼容旧版：广播给所有圈子成员
        info.circleIds.forEach(cid => {
          socket.to(cid).emit('interaction:care', {
            fromUserId: userId,
            fromUserName: user?.name || '某人',
            fromUserAvatarUrl: user?.avatar_url || null,
            timestamp: Date.now()
          });
        });
        // Bark 推送"想你"通知给同圈子其他成员（离线也能收到）
        notifyCare(userId, info.circleIds, user?.name || '某人');
      }
    });

    socket.on('disconnect', () => {
      const info = onlineUsers.get(socket.id);
      if (info) {
        info.circleIds.forEach(cid => socket.to(cid).emit('member:offline', { userId: info.userId, timestamp: Date.now() }));
      }
      onlineUsers.delete(socket.id);
    });
  });

  return onlineUsers;
}

function checkAlive() {
  const users = queryAll('SELECT id, name FROM users');
  users.forEach(u => {
    const lastLoc = queryOne('SELECT recorded_at FROM locations WHERE user_id = ? ORDER BY recorded_at DESC LIMIT 1', [u.id]);
    if (!lastLoc) return;
    const lastTime = new Date(lastLoc.recorded_at + 'Z');
    const hoursSince = (Date.now() - lastTime.getTime()) / 3600000;
    if (hoursSince >= config.ALIVE_WARNING_HOURS) {
        const circles = queryAll('SELECT circle_id FROM circle_members WHERE user_id = ?', [u.id]);
        const circleIds = circles.map(c => c.circle_id);
        circleIds.forEach(cid => {
          _io.to(cid).emit('alive:warning', {
            userId: u.id, userName: u.name,
            hours: Math.round(hoursSince),
            lastLocation: lastLoc.recorded_at,
            timestamp: Date.now()
          });
        });
        // Bark 推送长时间未活跃通知
        notifyAliveWarning(u.id, circleIds, u.name, Math.round(hoursSince));
      }
  });
}

function startAliveCheck() {
  setInterval(checkAlive, 3600000);
}

module.exports = { registerSocketHandlers, onlineUsers, checkAlive, startAliveCheck };
