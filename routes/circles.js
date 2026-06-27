const express = require('express');
const router = express.Router();
const crypto = require('crypto');
const { queryOne, queryAll, run } = require('../db');
const { requireAuth, requireUserAccess, requireCircleMember } = require('../middleware/auth');
const { validateBody, schemas } = require('../middleware/validate');

router.post('/api/circles', requireAuth, validateBody(schemas.createCircle), (req, res) => {
  // 安全修复：userId 从 token 中取，不允许伪造
  const userId = req.userId;
  const { name } = req.body;
  if (!name) return res.status(400).json({ error: '圈子名称不能为空' });
  const id = 'c_' + Date.now().toString(36) + Math.random().toString(36).substr(2, 5);
  const invite_code = crypto.randomBytes(4).toString('hex').toUpperCase().slice(0, 8);
  run('INSERT INTO circles (id, name, invite_code) VALUES (?, ?, ?)', [id, name, invite_code]);
  run('INSERT INTO circle_members (circle_id, user_id) VALUES (?, ?)', [id, userId]);
  res.json({ id, name, invite_code });
});

router.post('/api/circles/join', requireAuth, validateBody(schemas.joinCircle), (req, res) => {
  // 安全修复：userId 从 token 中取，不允许伪造
  const userId = req.userId;
  const { inviteCode } = req.body;
  if (!inviteCode) return res.status(400).json({ error: '邀请码不能为空' });
  const circle = queryOne('SELECT * FROM circles WHERE invite_code = ?', [inviteCode]);
  if (!circle) return res.status(404).json({ error: '邀请码无效' });
  const existing = queryOne('SELECT * FROM circle_members WHERE circle_id = ? AND user_id = ?', [circle.id, userId]);
  if (existing) return res.json({ circle, alreadyMember: true });
  run('INSERT INTO circle_members (circle_id, user_id) VALUES (?, ?)', [circle.id, userId]);

  const io = req.app.get('io');
  const userName = queryOne('SELECT name FROM users WHERE id = ?', [userId])?.name || '新成员';
  io.to(circle.id).emit('circle:join', {
    circleId: circle.id, userId, userName, timestamp: Date.now()
  });

  res.json({ circle, alreadyMember: false });
});

router.get('/api/users/:userId/circles', requireAuth, requireUserAccess, (req, res) => {
  const circles = queryAll(`SELECT c.*, (SELECT COUNT(*) FROM circle_members WHERE circle_id = c.id) as member_count
    FROM circles c JOIN circle_members cm ON c.id = cm.circle_id WHERE cm.user_id = ?`, [req.params.userId]);
  res.json(circles);
});

router.get('/api/circles/:circleId/members', requireAuth, requireCircleMember, (req, res) => {
  const members = queryAll(`SELECT u.id, u.name, u.avatar_color, u.avatar_url, u.mood, u.is_sleeping, u.ghost_mode,
    l.latitude, l.longitude, l.accuracy, l.battery_level, l.is_charging, l.speed, l.address, l.recorded_at,
    COALESCE(us.trail_skin, 'default') as trail_skin
    FROM users u JOIN circle_members cm ON u.id = cm.user_id
    LEFT JOIN locations l ON u.id = l.user_id
    LEFT JOIN user_settings us ON u.id = us.user_id WHERE cm.circle_id = ?`, [req.params.circleId]);
  const latest = {};
  members.forEach(m => {
    if (!latest[m.id] || (m.recorded_at && (!latest[m.id].recorded_at || m.recorded_at > latest[m.id].recorded_at))) {
      latest[m.id] = m;
    }
  });
  Object.values(latest).forEach(m => {
    if (!m.address || m.address.trim() === '') {
      const lastAddr = queryOne(
        "SELECT address FROM locations WHERE user_id = ? AND address IS NOT NULL AND address != '' ORDER BY recorded_at DESC LIMIT 1",
        [m.id]
      );
      if (lastAddr) m.address = lastAddr.address;
    }
    const stay = queryOne('SELECT * FROM stays WHERE user_id = ? AND ended_at IS NULL ORDER BY started_at DESC LIMIT 1', [m.id]);
    if (stay) {
      const mins = Math.round((Date.now() - new Date(stay.started_at + 'Z').getTime()) / 60000);
      m.stay_address = stay.address;
      m.stay_minutes = mins;
      m.stay_started_at = stay.started_at;
    }
  });
  res.json(Object.values(latest));
});

module.exports = router;
