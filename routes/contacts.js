const express = require('express');
const router = express.Router();
const { queryOne, queryAll, run } = require('../db');
const { requireAuth, requireUserAccess } = require('../middleware/auth');
const { validateBody, schemas } = require('../middleware/validate');

const addContactSchema = {
  contactId: { type: 'string', required: true },
  type: { type: 'string', enum: ['friend', 'family', 'colleague', 'other'] },
};

router.post('/api/contacts', requireAuth, (req, res) => {
  const userId = req.userId;
  const { contactId, type } = req.body;
  if (!contactId) return res.status(400).json({ error: 'contactId 不能为空' });
  const existing = queryOne('SELECT * FROM contacts WHERE user_id = ? AND contact_id = ?', [userId, contactId]);
  if (existing) return res.json({ ok: true, already: true });
  run('INSERT INTO contacts (user_id, contact_id, type) VALUES (?, ?, ?)', [userId, contactId, type || 'friend']);
  res.json({ ok: true });
});

router.delete('/api/contacts/:userId/:contactId', requireAuth, (req, res) => {
  // IDOR 修复：只能删除自己的联系人
  if (req.params.userId !== req.userId) return res.status(403).json({ error: '无权操作' });
  run('DELETE FROM contacts WHERE user_id = ? AND contact_id = ?', [req.params.userId, req.params.contactId]);
  res.json({ ok: true });
});

router.get('/api/users/:userId/contacts', requireAuth, requireUserAccess, (req, res) => {
  const contacts = queryAll('SELECT c.*, u.name, u.avatar_color, u.avatar_url FROM contacts c JOIN users u ON c.contact_id = u.id WHERE c.user_id = ?', [req.params.userId]);
  res.json(contacts);
});

router.get('/api/users/:userId/emergency-contacts', requireAuth, requireUserAccess, (req, res) => {
  const contacts = queryAll('SELECT * FROM emergency_contacts WHERE user_id = ?', [req.params.userId]);
  res.json(contacts);
});

router.post('/api/users/:userId/emergency-contacts', requireAuth, requireUserAccess, validateBody(schemas.createEmergencyContact), (req, res) => {
  const { name, phone, relation } = req.body;
  if (!name || !phone) return res.status(400).json({ error: '姓名和电话不能为空' });
  run('INSERT INTO emergency_contacts (user_id, name, phone, relation) VALUES (?, ?, ?, ?)',
    [req.params.userId, name, phone, relation || 'family']);
  res.json({ ok: true });
});

router.delete('/api/emergency-contacts/:id', requireAuth, (req, res) => {
  // IDOR 修复：验证紧急联系人归属
  const row = queryOne('SELECT user_id FROM emergency_contacts WHERE id = ?', [req.params.id]);
  if (!row) return res.status(404).json({ error: '联系人不存在' });
  if (row.user_id !== req.userId) return res.status(403).json({ error: '无权删除此联系人' });
  run('DELETE FROM emergency_contacts WHERE id = ?', [req.params.id]);
  res.json({ ok: true });
});

module.exports = router;
