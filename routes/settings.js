const express = require('express');
const router = express.Router();
const { queryOne, run } = require('../db');
const { requireAuth, requireUserAccess } = require('../middleware/auth');
const { validateBody, schemas } = require('../middleware/validate');

const updateSettingsSchema = {
  blur_location: { type: 'number' },
  share_paused: { type: 'number' },
  trail_skin: { type: 'string', maxLength: 30 },
  nickname_color: { type: 'string', maxLength: 20 },
  dark_mode: { type: 'number' },
  lang: { type: 'string', maxLength: 10 },
  bark_key: { type: 'string', maxLength: 50 },
};

router.get('/api/users/:userId/settings', requireAuth, requireUserAccess, (req, res) => {
  let s = queryOne('SELECT * FROM user_settings WHERE user_id = ?', [req.params.userId]);
  if (!s) { run('INSERT INTO user_settings (user_id) VALUES (?)', [req.params.userId]); s = { user_id: req.params.userId }; }
  res.json(s);
});

router.put('/api/users/:userId/settings', requireAuth, requireUserAccess, validateBody(updateSettingsSchema), (req, res) => {
  const fields = []; const values = [];
  ['blur_location', 'share_paused', 'trail_skin', 'nickname_color', 'dark_mode', 'lang', 'bark_key'].forEach(f => {
    if (req.body[f] !== undefined) { fields.push(`${f} = ?`); values.push(req.body[f]); }
  });
  if (fields.length > 0) { values.push(req.params.userId); run(`UPDATE user_settings SET ${fields.join(', ')} WHERE user_id = ?`, values); }
  res.json({ ok: true });
});

module.exports = router;
