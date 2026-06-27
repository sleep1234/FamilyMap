const express = require('express');
const router = express.Router();
const { queryOne, queryAll, run, hashPassword, createSession } = require('../db');
const { requireAuth, requireUserAccess } = require('../middleware/auth');
const { validateBody, schemas } = require('../middleware/validate');
const config = require('../config');

const legacyRegisterSchema = {
  name: { type: 'string', required: true, minLength: 1, maxLength: 50 },
};

router.post('/api/register', validateBody(schemas.register), async (req, res) => {
  const { username, password, name } = req.body;
  const existing = queryOne('SELECT id FROM users WHERE username = ?', [username]);
  if (existing) return res.status(409).json({ error: '用户名已被占用' });
  const id = 'u_' + Date.now().toString(36) + Math.random().toString(36).substr(2, 5);
  const colors = ['#4F46E5', '#EC4899', '#10B981', '#F59E0B', '#EF4444', '#8B5CF6', '#06B6D4', '#F97316'];
  const avatar_color = colors[Math.floor(Math.random() * colors.length)];
  const password_hash = await hashPassword(password);
  try {
    run('INSERT INTO users (id, name, avatar_color, username, password_hash) VALUES (?, ?, ?, ?, ?)',
      [id, name, avatar_color, username, password_hash]);
    run('INSERT INTO user_settings (user_id) VALUES (?)', [id]);
    const token = createSession(id, 'register');
    res.json({ id, name, avatar_color, username, token });
  } catch (e) {
    res.status(500).json({ error: '注册失败: ' + e.message });
  }
});

const crypto = require('crypto');

const LEGACY_PWD_SALT = process.env.PWD_SALT;

function verifyLegacyPassword(password, hash) {
  if (!LEGACY_PWD_SALT) return false;
  const sha256 = crypto.createHash('sha256').update(LEGACY_PWD_SALT + password).digest('hex');
  try {
    return crypto.timingSafeEqual(Buffer.from(sha256, 'hex'), Buffer.from(hash, 'hex'));
  } catch {
    return false;
  }
}

router.post('/api/login', validateBody(schemas.login), async (req, res) => {
  const { username, password, device_info } = req.body;
  const user = queryOne('SELECT * FROM users WHERE username = ?', [username]);
  if (!user) return res.status(401).json({ error: '用户名或密码错误' });

  if (!user.password_hash) {
    return res.status(401).json({ error: '该账号未设置密码，请重新注册' });
  }

  // bcrypt password (new format)
  if (user.password_hash.startsWith('$2a$')) {
    const passwordValid = await require('bcryptjs').compare(password, user.password_hash);
    if (!passwordValid) {
      return res.status(401).json({ error: '用户名或密码错误' });
    }
  }
  // SHA-256 legacy password — verify then auto-upgrade to bcrypt
  else if (verifyLegacyPassword(password, user.password_hash)) {
    const newHash = await require('bcryptjs').hash(password, config.BCRYPT_ROUNDS);
    run('UPDATE users SET password_hash = ? WHERE id = ?', [newHash, user.id]);
    console.log(`[密码升级] 用户 ${user.id} 的密码已从 SHA-256 升级为 bcrypt`);
  }
  else {
    return res.status(401).json({ error: '用户名或密码错误' });
  }

  const token = createSession(user.id, device_info || '');
  res.json({
    id: user.id, name: user.name, avatar_color: user.avatar_color,
    avatar_url: user.avatar_url || null,
    username: user.username, mood: user.mood, is_sleeping: user.is_sleeping,
    ghost_mode: user.ghost_mode, token,
  });
});

router.get('/api/users/:userId', requireAuth, requireUserAccess, (req, res) => {
  const user = queryOne('SELECT * FROM users WHERE id = ?', [req.params.userId]);
  if (!user) return res.status(404).json({ error: '用户不存在' });
  delete user.password_hash;
  res.json(user);
});

router.post('/api/logout', requireAuth, (req, res) => {
  const token = req.token;
  if (token) {
    run('DELETE FROM sessions WHERE token = ?', [token]);
  }
  res.json({ success: true });
});

const updateProfileSchema = {
  name: { type: 'string', maxLength: 50 },
  avatar_color: { type: 'string', maxLength: 20 },
  avatar_url: { type: 'string', maxLength: 500 },
  mood: { type: 'string', maxLength: 100 },
  is_sleeping: { type: 'number' },
  ghost_mode: { type: 'string', enum: ['off', 'invisible', 'blur'] },
};

router.put('/api/users/:userId', requireAuth, requireUserAccess, validateBody(updateProfileSchema), (req, res) => {
  const fields = [];
  const values = [];
  ['name', 'avatar_color', 'avatar_url', 'mood', 'is_sleeping', 'ghost_mode'].forEach(f => {
    if (req.body[f] !== undefined) { fields.push(`${f} = ?`); values.push(req.body[f]); }
  });
  if (fields.length === 0) return res.json({ ok: true });
  values.push(req.params.userId);
  run(`UPDATE users SET ${fields.join(', ')} WHERE id = ?`, values);
  res.json({ ok: true });
});

module.exports = router;
