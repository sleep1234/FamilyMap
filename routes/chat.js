const express = require('express');
const router = express.Router();
const { queryOne, queryAll, run } = require('../db');
const { requireAuth, requireCircleMember } = require('../middleware/auth');
const { validateBody, schemas } = require('../middleware/validate');
const { notifyChat } = require('../services/bark');

router.get('/api/circles/:circleId/messages', requireAuth, requireCircleMember, (req, res) => {
  const limit = parseInt(req.query.limit) || 50;
  const before = req.query.before;
  let sql = 'SELECT m.*, u.name, u.avatar_color, u.avatar_url FROM messages m JOIN users u ON m.user_id = u.id WHERE m.circle_id = ?';
  const params = [req.params.circleId];
  if (before) { sql += ' AND m.id < ?'; params.push(before); }
  sql += ' ORDER BY m.created_at DESC LIMIT ?';
  params.push(limit);
  const msgs = queryAll(sql, params).reverse();
  res.json(msgs);
});

router.post('/api/circles/:circleId/messages', requireAuth, requireCircleMember, validateBody(schemas.sendMessage), (req, res) => {
  // 安全修复：userId 从 token 中取，不允许客户端伪造
  const userId = req.userId;
  const { type, content } = req.body;
  run('INSERT INTO messages (circle_id, user_id, type, content) VALUES (?, ?, ?, ?)',
    [req.params.circleId, userId, type || 'text', content]);
  const row = queryOne('SELECT last_insert_rowid() as id');
  const user = queryOne('SELECT name, avatar_color, avatar_url FROM users WHERE id = ?', [userId]);
  const msg = {
    id: row.id, circle_id: req.params.circleId, user_id: userId, type: type || 'text', content,
    name: user?.name, avatar_color: user?.avatar_color, avatar_url: user?.avatar_url, created_at: new Date().toISOString()
  };
  const io = req.app.get('io');
  io.to(req.params.circleId).emit('chat:message', msg);
  // Bark 推送聊天消息给同圈子其他成员（离线也能收到）
  notifyChat(userId, req.params.circleId, user?.name || '未知', content, type || 'text');
  res.json(msg);
});

module.exports = router;
