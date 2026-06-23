// ==================== 输入验证中间件 ====================
// 轻量级验证，无需第三方依赖

/// 通用验证器：验证 req.body 中的字段
function validateBody(schema) {
  return (req, res, next) => {
    const errors = [];
    for (const [field, rules] of Object.entries(schema)) {
      const value = req.body[field];

      // 必填检查
      if (rules.required && (value === undefined || value === null || value === '')) {
        errors.push(`${field} 不能为空`);
        continue;
      }

      // 如果值不存在且非必填，跳过后续验证
      if (value === undefined || value === null) continue;

      // 类型检查
      if (rules.type === 'string' && typeof value !== 'string') {
        errors.push(`${field} 必须是字符串`);
        continue;
      }
      if (rules.type === 'number' && (typeof value !== 'number' || isNaN(value))) {
        errors.push(`${field} 必须是数字`);
        continue;
      }
      if (rules.type === 'boolean' && typeof value !== 'boolean') {
        errors.push(`${field} 必须是布尔值`);
        continue;
      }

      // 字符串长度
      if (rules.type === 'string') {
        if (rules.minLength && value.length < rules.minLength) {
          errors.push(`${field} 至少 ${rules.minLength} 个字符`);
        }
        if (rules.maxLength && value.length > rules.maxLength) {
          errors.push(`${field} 最多 ${rules.maxLength} 个字符`);
        }
        // 正则匹配
        if (rules.pattern && !rules.pattern.test(value)) {
          errors.push(`${field} 格式不正确`);
        }
      }

      // 数字范围
      if (rules.type === 'number') {
        if (rules.min !== undefined && value < rules.min) {
          errors.push(`${field} 不能小于 ${rules.min}`);
        }
        if (rules.max !== undefined && value > rules.max) {
          errors.push(`${field} 不能大于 ${rules.max}`);
        }
      }

      // 枚举值
      if (rules.enum && !rules.enum.includes(value)) {
        errors.push(`${field} 必须是以下值之一: ${rules.enum.join(', ')}`);
      }
    }

    if (errors.length > 0) {
      return res.status(400).json({ error: errors.join('; ') });
    }
    next();
  };
}

/// 通用查询参数验证器
function validateQuery(schema) {
  return (req, res, next) => {
    const errors = [];
    for (const [field, rules] of Object.entries(schema)) {
      const value = req.query[field];

      if (rules.required && (value === undefined || value === null || value === '')) {
        errors.push(`${field} 不能为空`);
        continue;
      }

      if (value === undefined || value === null) continue;

      // 数字类型转换
      if (rules.type === 'number') {
        const num = parseFloat(value);
        if (isNaN(num)) {
          errors.push(`${field} 必须是数字`);
          continue;
        }
        req.query[field] = num; // 转换为数字
        if (rules.min !== undefined && num < rules.min) errors.push(`${field} 不能小于 ${rules.min}`);
        if (rules.max !== undefined && num > rules.max) errors.push(`${field} 不能大于 ${rules.max}`);
      }

      // 字符串格式
      if (rules.type === 'string' && rules.pattern && !rules.pattern.test(value)) {
        errors.push(`${field} 格式不正确`);
      }
    }

    if (errors.length > 0) {
      return res.status(400).json({ error: errors.join('; ') });
    }
    next();
  };
}

/// 预定义验证 schema
const schemas = {
  // 注册
  register: {
    username: { type: 'string', required: true, minLength: 3, maxLength: 30, pattern: /^[a-zA-Z0-9_]+$/ },
    password: { type: 'string', required: true, minLength: 4, maxLength: 100 },
    name: { type: 'string', required: true, minLength: 1, maxLength: 50 },
  },

  // 登录
  login: {
    username: { type: 'string', required: true },
    password: { type: 'string', required: true },
  },

  // 位置更新
  locationUpdate: {
    userId: { type: 'string', required: true },
    latitude: { type: 'number', required: true, min: -90, max: 90 },
    longitude: { type: 'number', required: true, min: -180, max: 180 },
    accuracy: { type: 'number', min: 0, max: 1000 },
    batteryLevel: { type: 'number', min: 0, max: 100 },
    isCharging: { type: 'boolean' },
    speed: { type: 'number', min: 0, max: 200 },
  },

  // 创建圈子
  createCircle: {
    name: { type: 'string', required: true, minLength: 1, maxLength: 50 },
  },

  // 加入圈子
  joinCircle: {
    inviteCode: { type: 'string', required: true, minLength: 4, maxLength: 20 },
  },

  // 创建围栏
  createGeofence: {
    name: { type: 'string', required: true, minLength: 1, maxLength: 50 },
    latitude: { type: 'number', required: true, min: -90, max: 90 },
    longitude: { type: 'number', required: true, min: -180, max: 180 },
    radius: { type: 'number', min: 50, max: 5000 },
  },

  // 发送消息
  sendMessage: {
    content: { type: 'string', required: true, minLength: 1, maxLength: 1000 },
  },

  // SOS
  sendSos: {
    latitude: { type: 'number', required: true, min: -90, max: 90 },
    longitude: { type: 'number', required: true, min: -180, max: 180 },
  },

  // 足迹
  createFootprint: {
    name: { type: 'string', required: true, minLength: 1, maxLength: 50 },
    latitude: { type: 'number', required: true, min: -90, max: 90 },
    longitude: { type: 'number', required: true, min: -180, max: 180 },
    category: { type: 'string', enum: ['home', 'work', 'school', 'food', 'fun', 'hospital', 'other'] },
    note: { type: 'string', required: false, maxLength: 500 },
  },

  // 紧急联系人
  createEmergencyContact: {
    name: { type: 'string', required: true, minLength: 1, maxLength: 50 },
    phone: { type: 'string', required: true, minLength: 5, maxLength: 20 },
    relation: { type: 'string', enum: ['family', 'friend', 'colleague', 'other'] },
  },

  // 用户设置
  updateSettings: {
    blur_location: { type: 'number', enum: [0, 1] },
    share_paused: { type: 'number', enum: [0, 1] },
    trail_skin: { type: 'string', enum: ['default', 'fire', 'ice', 'rainbow', 'galaxy'] },
    nickname_color: { type: 'string', maxLength: 20 },
    dark_mode: { type: 'number', enum: [0, 1] },
    lang: { type: 'string', enum: ['zh', 'en'] },
  },

  // 分享链接
  shareLink: {
    latitude: { type: 'number', required: true, min: -90, max: 90 },
    longitude: { type: 'number', required: true, min: -180, max: 180 },
    durationMinutes: { type: 'number', min: 1, max: 1440 },
  },

  // 查询参数
  queryHours: {
    hours: { type: 'number', min: 1, max: 720 },
  },
  queryDays: {
    days: { type: 'number', min: 1, max: 365 },
  },
  queryDate: {
    date: { type: 'string', pattern: /^\d{4}-\d{2}-\d{2}$/ },
  },
  queryGeocode: {
    lat: { type: 'number', required: true, min: -90, max: 90 },
    lng: { type: 'number', required: true, min: -180, max: 180 },
  },
  queryEta: {
    fromLat: { type: 'number', required: true, min: -90, max: 90 },
    fromLng: { type: 'number', required: true, min: -180, max: 180 },
    toLat: { type: 'number', required: true, min: -90, max: 90 },
    toLng: { type: 'number', required: true, min: -180, max: 180 },
    speed: { type: 'number', min: 0.5, max: 200 },
  },
};

module.exports = { validateBody, validateQuery, schemas };
