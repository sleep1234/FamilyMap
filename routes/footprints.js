const express = require('express');
const router = express.Router();
const { queryAll, queryOne, run } = require('../db');
const { requireAuth, requireUserAccess } = require('../middleware/auth');
const { validateBody, schemas } = require('../middleware/validate');

router.get('/api/users/:userId/footprints', requireAuth, requireUserAccess, (req, res) => {
  res.json(queryAll('SELECT * FROM footprints WHERE user_id = ? ORDER BY created_at DESC', [req.params.userId]));
});

router.post('/api/users/:userId/footprints', requireAuth, requireUserAccess, validateBody(schemas.createFootprint), (req, res) => {
  const { name, latitude, longitude, category, note } = req.body;
  run('INSERT INTO footprints (user_id, name, latitude, longitude, category, note) VALUES (?, ?, ?, ?, ?, ?)',
    [req.params.userId, name, latitude, longitude, category || 'other', note || '']);
  const row = queryOne('SELECT last_insert_rowid() as id');
  res.json({ id: row.id, name, latitude, longitude, category: category || 'other', note: note || '' });
});

router.delete('/api/footprints/:id', requireAuth, (req, res) => {
  // IDOR 修复：验证足迹归属
  const row = queryOne('SELECT user_id FROM footprints WHERE id = ?', [req.params.id]);
  if (!row) return res.status(404).json({ error: '足迹不存在' });
  if (row.user_id !== req.userId) return res.status(403).json({ error: '无权删除此足迹' });
  run('DELETE FROM footprints WHERE id = ?', [req.params.id]);
  res.json({ ok: true });
});

module.exports = router;
