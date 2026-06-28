/**
 * Bark 推送通知服务
 * 每个用户在设置中绑定自己的 Bark Key，
 * 事件触发时推送给相关用户（同圈子其他成员）
 */
const https = require('https');
const http = require('http');
const { queryAll, queryOne } = require('../db');

const BARK_BASE = 'https://api.day.app';
const BARK_ICON = 'https://www.zhp98.fun:8090/uploads/presets/bark_icon.png';

/**
 * HTTP POST 请求（Bark 推荐方式，支持更多参数）
 */
function _httpPost(url, body) {
  return new Promise((resolve, reject) => {
    const mod = url.startsWith('https') ? https : http;
    const data = JSON.stringify(body);
    const req = mod.request(url, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(data) },
    }, (res) => {
      let chunk = '';
      res.on('data', d => chunk += d);
      res.on('end', () => {
        try {
          const json = JSON.parse(chunk);
          if (json.code === 200) {
            resolve(json);
          } else {
            reject(new Error(`Bark API error: ${json.message || chunk}`));
          }
        } catch {
          reject(new Error(`Bark API invalid response: ${chunk.substring(0, 100)}`));
        }
      });
    });
    req.on('error', reject);
    req.setTimeout(5000, () => { req.destroy(); reject(new Error('timeout')); });
    req.write(data);
    req.end();
  });
}

/**
 * HTTP GET 请求（兼容旧版）
 */
function _httpGet(url) {
  return new Promise((resolve, reject) => {
    const mod = url.startsWith('https') ? https : http;
    const req = mod.get(url, (res) => {
      let data = '';
      res.on('data', chunk => data += chunk);
      res.on('end', () => {
        try {
          const json = JSON.parse(data);
          if (json.code === 200) {
            resolve(json);
          } else {
            reject(new Error(`Bark API error: ${json.message || data}`));
          }
        } catch {
          reject(new Error(`Bark API invalid response: ${data.substring(0, 100)}`));
        }
      });
    });
    req.on('error', reject);
    req.setTimeout(5000, () => { req.destroy(); reject(new Error('timeout')); });
  });
}

/**
 * 向指定用户发送 Bark 推送
 * @param {string[]} targetUserIds - 目标用户 ID 列表
 * @param {string} title - 推送标题
 * @param {string} body - 推送内容
 * @param {Object} options - 可选参数
 */
async function sendBarkToUsers(targetUserIds, title, body, options = {}) {
  if (!targetUserIds || targetUserIds.length === 0) return;

  // 查询这些用户的 bark_key
  for (const uid of targetUserIds) {
    try {
      const settings = queryOne('SELECT bark_key FROM user_settings WHERE user_id = ?', [uid]);
      const barkKey = settings?.bark_key;
      if (!barkKey) continue; // 该用户未配置 Bark，跳过

      // 使用 POST 方式推送（比 GET 更可靠，支持 icon 等参数）
      const payload = {
        device_key: barkKey,
        title,
        body,
        icon: options.icon || BARK_ICON,
        group: options.group || 'familymap',
      };
      if (options.sound) payload.sound = options.sound;
      if (options.url) payload.url = options.url;

      await _httpPost(`${BARK_BASE}/push`, payload);
    } catch (err) {
      console.error(`[Bark] 推送失败 userId=${uid}:`, err.message);
    }
  }
}

/**
 * 获取同圈子其他成员的用户 ID（排除触发者自己）
 */
function getCircleMemberIds(circleIds, excludeUserId) {
  const memberIds = new Set();
  for (const cid of circleIds) {
    const members = queryAll('SELECT user_id FROM circle_members WHERE circle_id = ?', [cid]);
    for (const m of members) {
      if (m.user_id !== excludeUserId) {
        memberIds.add(m.user_id);
      }
    }
  }
  return [...memberIds];
}

/**
 * SOS 紧急求救推送 → 推送给同圈子其他成员
 */
async function notifySos(fromUserId, circleIds, userName, address) {
  const targetIds = getCircleMemberIds(circleIds, fromUserId);
  await sendBarkToUsers(targetIds,
    '🆘 SOS 紧急求救',
    `${userName} 发出了 SOS 求救信号！位置：${address || '未知'}`,
    { group: 'sos', sound: 'alarm' }
  );
}

/**
 * 地理围栏通知推送 → 推送给同圈子其他成员
 */
async function notifyGeofence(fromUserId, circleIds, userName, fenceName, action) {
  const targetIds = getCircleMemberIds(circleIds, fromUserId);
  const actionText = action === 'entered' ? '进入了' : '离开了';
  await sendBarkToUsers(targetIds,
    '📍 地理围栏提醒',
    `${userName} ${actionText}「${fenceName}」`,
    { group: 'geofence' }
  );
}

/**
 * 低电量提醒推送 → 推送给同圈子其他成员
 */
async function notifyLowBattery(fromUserId, circleIds, userName, batteryLevel) {
  const targetIds = getCircleMemberIds(circleIds, fromUserId);
  await sendBarkToUsers(targetIds,
    '🔋 低电量提醒',
    `${userName} 的手机电量仅剩 ${batteryLevel}%`,
    { group: 'battery' }
  );
}

/**
 * 碰撞检测推送 → 推送给同圈子其他成员
 */
async function notifyCollision(fromUserId, circleIds, userName, speed) {
  const targetIds = getCircleMemberIds(circleIds, fromUserId);
  await sendBarkToUsers(targetIds,
    '⚠️ 异常靠近提醒',
    `${userName} 以 ${(speed * 3.6).toFixed(0)}km/h 高速移动，请注意安全！`,
    { group: 'collision', sound: 'alarm' }
  );
}

/**
 * 长时间未活跃提醒推送 → 推送给同圈子其他成员
 */
async function notifyAliveWarning(userId, circleIds, userName, hours) {
  const targetIds = getCircleMemberIds(circleIds, userId);
  await sendBarkToUsers(targetIds,
    '🕐 长时间未活跃',
    `${userName} 已 ${hours} 小时未更新位置`,
    { group: 'alive' }
  );
}

/**
 * 停留/离开通知推送 → 推送给同圈子其他成员
 */
async function notifyTripReport(userId, circleIds, userName, action, address, duration, stayType) {
  const targetIds = getCircleMemberIds(circleIds, userId);
  const actionText = action === 'left' ? '离开了' : '到达了';
  const typeEmoji = { home: '🏠', work: '🏢', school: '🏫', food: '🍜', fun: '🎉', hospital: '🏥' }[stayType] || '📍';
  await sendBarkToUsers(targetIds,
    `${typeEmoji} ${userName} ${actionText}`,
    `位置：${address || '某地'}${duration > 0 ? `，停留了${duration}分钟` : ''}`,
    { group: 'trip' }
  );
}

/**
 * 到家/离家状态推送 → 推送给同圈子其他成员
 */
async function notifyHomeStatus(userId, circleIds, userName, action, address, distance) {
  const targetIds = getCircleMemberIds(circleIds, userId);
  const actionText = action === 'left' ? '离开了家' : '到家了';
  await sendBarkToUsers(targetIds,
    `🏠 ${userName} ${actionText}`,
    `${address || ''}${distance ? `，距离${distance}m` : ''}`,
    { group: 'home' }
  );
}

/**
 * Emoji炸弹互动推送 → 推送给同圈子其他成员
 */
async function notifyEmojiBomb(userId, circleIds, userName, emoji) {
  const targetIds = getCircleMemberIds(circleIds, userId);
  await sendBarkToUsers(targetIds,
    `${emoji} ${userName}`,
    `给你发了一个${emoji}`,
    { group: 'emoji' }
  );
}

/**
 * 聊天消息推送 → 推送给同圈子其他成员
 */
async function notifyChat(fromUserId, circleId, userName, content, msgType) {
  // 查询同圈子其他成员
  const members = queryAll('SELECT user_id FROM circle_members WHERE circle_id = ? AND user_id != ?', [circleId, fromUserId]);
  const targetIds = members.map(m => m.user_id);
  // 根据消息类型生成预览
  let preview;
  if (msgType === 'audio') {
    preview = '[语音消息]';
  } else if (msgType === 'image') {
    preview = '[图片]';
  } else {
    preview = (content && content.length > 50) ? content.substring(0, 50) + '...' : (content || '');
  }
  await sendBarkToUsers(targetIds,
    '💬 新消息',
    `${userName}: ${preview}`,
    { group: 'chat' }
  );
}

/**
 * "想你"互动推送 → 推送给同圈子其他成员
 */
async function notifyCare(fromUserId, targetUserIdsOrCircleIds, userName) {
  // 判断是直接用户ID列表还是圈子ID列表
  let targetIds;
  if (targetUserIdsOrCircleIds.length === 1) {
    // 单个ID，可能是目标用户ID
    const isUser = queryOne('SELECT id FROM users WHERE id = ?', [targetUserIdsOrCircleIds[0]]);
    if (isUser) {
      targetIds = targetUserIdsOrCircleIds;
    } else {
      targetIds = getCircleMemberIds(targetUserIdsOrCircleIds, fromUserId);
    }
  } else {
    targetIds = getCircleMemberIds(targetUserIdsOrCircleIds, fromUserId);
  }
  
  await sendBarkToUsers(targetIds,
    '💕 想你',
    `${userName} 想你了~`,
    { group: 'care', sound: 'bell' }
  );
}

module.exports = {
  sendBarkToUsers,
  notifySos,
  notifyGeofence,
  notifyLowBattery,
  notifyCollision,
  notifyAliveWarning,
  notifyCare,
  notifyChat,
  notifyTripReport,
  notifyHomeStatus,
  notifyEmojiBomb
};
