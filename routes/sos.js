const express = require('express');
const router = express.Router();
const { queryOne, queryAll, run } = require('../db');
const { requireAuth } = require('../middleware/auth');
const { validateBody, schemas } = require('../middleware/validate');
const { reverseGeocode } = require('../services/geocode');
const { notifySos } = require('../services/bark');

router.post('/api/sos', requireAuth, validateBody(schemas.sendSos), async (req, res) => {
  const { userId, latitude, longitude } = req.body;
  const geoResult = await reverseGeocode(latitude, longitude);
  run('INSERT INTO sos_alerts (user_id, latitude, longitude, address) VALUES (?, ?, ?, ?)',
    [userId, latitude, longitude, geoResult.address]);
  const user = queryOne('SELECT name FROM users WHERE id = ?', [userId]);
  const io = req.app.get('io');
  const circles = queryAll('SELECT circle_id FROM circle_members WHERE user_id = ?', [userId]);
  circles.forEach(c => {
    io.to(c.circle_id).emit('sos:alert', {
      userId, userName: user?.name || '未知',
      latitude, longitude, address: geoResult.address,
      timestamp: Date.now()
    });
  });
  // Bark 推送 SOS 通知给同圈子其他成员
  notifySos(userId, circles.map(c => c.circle_id), user?.name || '未知', geoResult.address);
  res.json({ ok: true, address: geoResult.address });
});

router.put('/api/sos/:id/resolve', requireAuth, (req, res) => {
  // IDOR 修复：只有 SOS 发起人或同圈子成员可解除
  const alert = queryOne('SELECT user_id FROM sos_alerts WHERE id = ?', [req.params.id]);
  if (!alert) return res.status(404).json({ error: 'SOS不存在' });
  const isOwner = alert.user_id === req.userId;
  const isMember = queryOne(
    `SELECT 1 FROM circle_members cm WHERE cm.user_id = ? AND cm.circle_id IN (
      SELECT circle_id FROM circle_members WHERE user_id = ?
    )`, [req.userId, alert.user_id]);
  if (!isOwner && !isMember) return res.status(403).json({ error: '无权操作此SOS' });
  run('UPDATE sos_alerts SET status = ? WHERE id = ?', ['resolved', req.params.id]);
  res.json({ ok: true });
});

module.exports = router;
