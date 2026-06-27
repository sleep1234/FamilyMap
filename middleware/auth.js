const { queryOne, queryAll, verifySession } = require('../db');

let _queryOne = queryOne;
let _queryAll = queryAll;

function initAuth() {
  _queryOne = queryOne;
  _queryAll = queryAll;
}

function requireAuth(req, res, next) {
  const authHeader = req.headers.authorization;
  if (!authHeader || !authHeader.startsWith('Bearer ')) {
    return res.status(401).json({ error: '未登录，请先登录' });
  }
  const token = authHeader.substring(7);
  if (!token) {
    return res.status(401).json({ error: '会话 token 无效' });
  }
  if (!_queryOne) {
    return res.status(500).json({ error: '认证模块未初始化' });
  }
  // 使用 verifySession 统一检查过期（7天）并更新 last_active
  const userId = verifySession(token);
  if (!userId) {
    return res.status(401).json({ error: '会话已过期，请重新登录' });
  }
  req.userId = userId;
  req.token = token;
  next();
}

const ADMIN_USER_IDS = (process.env.ADMIN_USER_IDS || '').split(',').filter(Boolean);

function requireAdmin(req, res, next) {
  if (!req.userId) return res.status(401).json({ error: '未登录' });
  if (ADMIN_USER_IDS.length === 0) {
    return res.status(403).json({ error: '管理员未配置' });
  }
  if (!ADMIN_USER_IDS.includes(req.userId)) {
    return res.status(403).json({ error: '无管理员权限' });
  }
  next();
}

function requireUserAccess(req, res, next) {
  const targetUserId = req.params.userId;
  if (!req.userId) return res.status(401).json({ error: '未登录' });
  if (req.userId === targetUserId) return next();
  const shared = _queryOne(
    `SELECT 1 FROM circle_members WHERE user_id = ? AND circle_id IN (SELECT circle_id FROM circle_members WHERE user_id = ?) LIMIT 1`,
    [req.userId, targetUserId]
  );
  if (shared) return next();
  return res.status(403).json({ error: '无权访问该用户数据' });
}

function requireCircleMember(req, res, next) {
  const circleId = req.params.circleId;
  if (!req.userId) return res.status(401).json({ error: '未登录' });
  const member = _queryOne(
    'SELECT 1 FROM circle_members WHERE circle_id = ? AND user_id = ?',
    [circleId, req.userId]
  );
  if (!member) return res.status(403).json({ error: '不是该圈子成员' });
  next();
}

function optionalAuth(req, res, next) {
  const authHeader = req.headers.authorization;
  if (authHeader && authHeader.startsWith('Bearer ')) {
    const token = authHeader.substring(7);
    if (_queryOne && token) {
      const userId = verifySession(token);
      if (userId) {
        req.userId = userId;
        req.token = token;
      }
    }
  }
  next();
}

module.exports = { initAuth, requireAuth, requireAdmin, requireUserAccess, requireCircleMember, optionalAuth };
