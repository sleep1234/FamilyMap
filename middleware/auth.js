// ==================== API 认证中间件 ====================
// 验证 session token，保护需要登录的 API

/// 数据库查询助手（从 server.js 导入）
let _queryOne = null;

/// 初始化认证模块（传入查询函数）
function initAuth(queryOneFn) {
  _queryOne = queryOneFn;
}

/// 认证中间件：验证请求头中的 Authorization token
function requireAuth(req, res, next) {
  const authHeader = req.headers.authorization;
  if (!authHeader || !authHeader.startsWith('Bearer ')) {
    return res.status(401).json({ error: '未登录，请先登录' });
  }

  const token = authHeader.substring(7); // 去掉 'Bearer ' 前缀
  if (!token) {
    return res.status(401).json({ error: '会话 token 无效' });
  }

  if (!_queryOne) {
    return res.status(500).json({ error: '认证模块未初始化' });
  }

  const session = _queryOne('SELECT user_id FROM sessions WHERE token = ?', [token]);
  if (!session) {
    return res.status(401).json({ error: '会话已过期，请重新登录' });
  }

  // 将 userId 附加到请求对象，后续路由可使用
  req.userId = session.user_id;
  req.token = token;
  next();
}

/// 可选认证中间件：如果有 token 就验证，没有也放行
function optionalAuth(req, res, next) {
  const authHeader = req.headers.authorization;
  if (authHeader && authHeader.startsWith('Bearer ')) {
    const token = authHeader.substring(7);
    if (_queryOne && token) {
      const session = _queryOne('SELECT user_id FROM sessions WHERE token = ?', [token]);
      if (session) {
        req.userId = session.user_id;
        req.token = token;
      }
    }
  }
  next();
}

module.exports = { initAuth, requireAuth, optionalAuth };
