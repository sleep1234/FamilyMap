const express = require('express');
const router = express.Router();
const { queryAll, queryOne, run } = require('../db');
const { requireAuth, requireCircleMember } = require('../middleware/auth');
const { validateBody, schemas } = require('../middleware/validate');

router.get('/api/circles/:circleId/geofences', requireAuth, requireCircleMember, (req, res) => {
  res.json(queryAll('SELECT * FROM geofences WHERE circle_id = ?', [req.params.circleId]));
});

router.post('/api/circles/:circleId/geofences', requireAuth, requireCircleMember, validateBody(schemas.createGeofence), (req, res) => {
  const { name, latitude, longitude, radius } = req.body;
  const createdBy = req.userId;
  run('INSERT INTO geofences (circle_id, name, latitude, longitude, radius, created_by) VALUES (?, ?, ?, ?, ?, ?)',
    [req.params.circleId, name, latitude, longitude, radius || 200, createdBy]);
  const row = queryOne('SELECT last_insert_rowid() as id');
  res.json({ id: row.id, name, latitude, longitude, radius: radius || 200 });
});

router.delete('/api/geofences/:id', requireAuth, (req, res) => {
  // IDOR 修复：验证围栏归属（只有圈子成员可删除）
  const row = queryOne('SELECT circle_id FROM geofences WHERE id = ?', [req.params.id]);
  if (!row) return res.status(404).json({ error: '围栏不存在' });
  const membership = queryOne('SELECT 1 FROM circle_members WHERE circle_id = ? AND user_id = ?', [row.circle_id, req.userId]);
  if (!membership) return res.status(403).json({ error: '无权删除此围栏' });
  run('DELETE FROM geofences WHERE id = ?', [req.params.id]);
  res.json({ ok: true });
});

module.exports = router;
