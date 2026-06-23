const express = require('express');
const router = express.Router();
const multer = require('multer');
const path = require('path');
const fs = require('fs');
const { queryOne, run } = require('../db');
const { requireAuth } = require('../middleware/auth');

// ==================== 音频上传目录 ====================
const AUDIO_DIR = path.join(__dirname, '..', 'uploads', 'audio');

if (!fs.existsSync(AUDIO_DIR)) {
  fs.mkdirSync(AUDIO_DIR, { recursive: true });
}

// ==================== Multer 配置 ====================
const storage = multer.diskStorage({
  destination: (req, file, cb) => cb(null, AUDIO_DIR),
  filename: (req, file, cb) => {
    const name = `${req.userId}_${Date.now()}.m4a`;
    cb(null, name);
  },
});

const upload = multer({
  storage,
  limits: { fileSize: 10 * 1024 * 1024 }, // 10MB
  fileFilter: (req, file, cb) => {
    const allowed = ['.m4a', '.aac', '.mp4', '.wav', '.ogg', '.amr'];
    const ext = path.extname(file.originalname).toLowerCase();
    if (allowed.includes(ext) || file.mimetype.startsWith('audio/')) {
      cb(null, true);
    } else {
      cb(new Error('仅支持音频格式'));
    }
  },
});

// ==================== 音频上传接口 ====================

router.post('/api/upload/audio', requireAuth, upload.single('audio'), (req, res) => {
  if (!req.file) return res.status(400).json({ error: '未提供音频文件' });

  const url = `/uploads/audio/${req.file.filename}`;
  const duration = parseInt(req.body.duration) || 0;

  res.json({
    url,
    duration,
    size: req.file.size,
  });
});

// 静态文件服务：/uploads/audio/*
// (由 server.js 中的 express.static 统一处理)

module.exports = router;
