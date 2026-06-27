const express = require('express');
const router = express.Router();
const multer = require('multer');
const path = require('path');
const fs = require('fs');
const crypto = require('crypto');
const { queryOne, run } = require('../db');
const { requireAuth, requireUserAccess } = require('../middleware/auth');

// ==================== 上传目录配置 ====================
const UPLOAD_DIR = path.join(__dirname, '..', 'uploads', 'avatars');
const PRESET_DIR = path.join(__dirname, '..', 'uploads', 'presets');

// 确保目录存在
[UPLOAD_DIR, PRESET_DIR].forEach(dir => {
  if (!fs.existsSync(dir)) {
    fs.mkdirSync(dir, { recursive: true });
  }
});

// ==================== Multer 配置 ====================
const storage = multer.diskStorage({
  destination: (req, file, cb) => cb(null, UPLOAD_DIR),
  filename: (req, file, cb) => {
    const ext = path.extname(file.originalname) || '.jpg';
    const name = `${req.params.userId}_${Date.now()}${ext}`;
    cb(null, name);
  },
});

const upload = multer({
  storage,
  limits: { fileSize: 2 * 1024 * 1024 }, // 2MB
  fileFilter: (req, file, cb) => {
    const allowed = ['.jpg', '.jpeg', '.png', '.webp'];
    const ext = path.extname(file.originalname).toLowerCase();
    if (allowed.includes(ext)) {
      cb(null, true);
    } else {
      cb(new Error('仅支持 JPG/PNG/WebP 格式'));
    }
  },
});

// ==================== 上传自定义头像 ====================
router.post('/api/users/:userId/avatar', requireAuth, requireUserAccess, upload.single('avatar'), (req, res) => {
  if (!req.file) {
    return res.status(400).json({ error: '请选择头像文件' });
  }

  const userId = req.params.userId;
  const relativePath = `/uploads/avatars/${req.file.filename}`;

  // 删除旧的自定义头像文件（如果存在且不是预设头像）
  const oldUser = queryOne('SELECT avatar_url FROM users WHERE id = ?', [userId]);
  if (oldUser && oldUser.avatar_url && oldUser.avatar_url.includes('/avatars/')) {
    const oldFilename = path.basename(oldUser.avatar_url);
    const oldFilePath = path.join(UPLOAD_DIR, oldFilename);
    if (fs.existsSync(oldFilePath)) {
      try { fs.unlinkSync(oldFilePath); } catch (_) {}
    }
  }

  // 更新数据库
  run('UPDATE users SET avatar_url = ? WHERE id = ?', [relativePath, userId]);

  res.json({ ok: true, avatar_url: relativePath });
});

// ==================== 设置预设头像 ====================
router.put('/api/users/:userId/avatar', requireAuth, requireUserAccess, (req, res) => {
  const { avatar_url } = req.body;
  if (!avatar_url) {
    return res.status(400).json({ error: '头像URL不能为空' });
  }

  // 只允许预设头像路径或空字符串（清除头像）
  const isPreset = avatar_url.startsWith('/uploads/presets/');
  const isEmpty = avatar_url === '';
  if (!isPreset && !isEmpty) {
    return res.status(400).json({ error: '仅支持预设头像' });
  }

  const userId = req.params.userId;

  // 删除旧的自定义头像文件
  const oldUser = queryOne('SELECT avatar_url FROM users WHERE id = ?', [userId]);
  if (oldUser && oldUser.avatar_url && oldUser.avatar_url.includes('/avatars/')) {
    const oldFilename = path.basename(oldUser.avatar_url);
    const oldFilePath = path.join(UPLOAD_DIR, oldFilename);
    if (fs.existsSync(oldFilePath)) {
      try { fs.unlinkSync(oldFilePath); } catch (_) {}
    }
  }

  run('UPDATE users SET avatar_url = ? WHERE id = ?', [avatar_url, userId]);
  res.json({ ok: true, avatar_url });
});

// ==================== 删除头像（恢复默认颜色头像） ====================
router.delete('/api/users/:userId/avatar', requireAuth, requireUserAccess, (req, res) => {
  const userId = req.params.userId;

  const oldUser = queryOne('SELECT avatar_url FROM users WHERE id = ?', [userId]);
  if (oldUser && oldUser.avatar_url && oldUser.avatar_url.includes('/avatars/')) {
    const oldFilename = path.basename(oldUser.avatar_url);
    const oldFilePath = path.join(UPLOAD_DIR, oldFilename);
    if (fs.existsSync(oldFilePath)) {
      try { fs.unlinkSync(oldFilePath); } catch (_) {}
    }
  }

  run('UPDATE users SET avatar_url = NULL WHERE id = ?', [userId]);
  res.json({ ok: true });
});

// ==================== 获取预设头像列表 ====================
router.get('/api/avatars/presets', (req, res) => {
  // 扫描预设头像目录
  let files = [];
  try {
    files = fs.readdirSync(PRESET_DIR)
      .filter(f => /\.(jpg|jpeg|png|webp)$/i.test(f))
      .sort()
      .map(f => ({
        id: path.basename(f, path.extname(f)),
        url: `/uploads/presets/${f}`,
      }));
  } catch (_) {}

  // 如果预设目录为空，返回内置的emoji-style预设列表
  if (files.length === 0) {
    const builtinPresets = [
      'cat', 'dog', 'bear', 'fox', 'panda', 'rabbit',
      'star', 'moon', 'sun', 'cloud', 'flower', 'tree',
      'car', 'bike', 'plane', 'boat', 'rocket', 'train',
    ];
    files = builtinPresets.map(id => ({
      id,
      url: `/uploads/presets/${id}.png`,
      builtin: true,
    }));
  }

  res.json({ presets: files });
});

// Multer 错误处理
router.use((err, req, res, next) => {
  if (err.code === 'LIMIT_FILE_SIZE') {
    return res.status(400).json({ error: '头像文件不能超过2MB' });
  }
  if (err.message) {
    return res.status(400).json({ error: err.message });
  }
  next(err);
});

module.exports = router;
