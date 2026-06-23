const express = require('express');
const http = require('http');
const https = require('https');
const fs = require('fs');
const { Server } = require('socket.io');
const path = require('path');
const rateLimit = require('express-rate-limit');
const config = require('./config');
const db = require('./db');
const { initAuth } = require('./middleware/auth');
const registerRoutes = require('./routes/index');
const { registerSocketHandlers, checkAlive, startAliveCheck } = require('./socket/handler');
const { checkGeocodeRefreshSchedule } = require('./services/geocode');
const { startStayTimeoutCleanup } = require('./services/stay');
const { startCleanupInterval: startShareCleanup } = require('./services/share');

const app = express();

// HTTPS 配置
const SSL_CERT_PATH = process.env.SSL_CERT_PATH || path.join(__dirname, 'ssl_cert.pem');
const SSL_KEY_PATH = process.env.SSL_KEY_PATH || path.join(__dirname, 'ssl_key.pem');
const useHttps = fs.existsSync(SSL_CERT_PATH) && fs.existsSync(SSL_KEY_PATH);

let server;
if (useHttps) {
  const sslOptions = {
    cert: fs.readFileSync(SSL_CERT_PATH),
    key: fs.readFileSync(SSL_KEY_PATH),
  };
  server = https.createServer(sslOptions, app);
  console.log('  HTTPS: 已启用 (SSL证书已加载)');
} else {
  server = http.createServer(app);
  console.log('  HTTPS: 未启用 (未找到ssl_cert.pem/ssl_key.pem)');
}

const io = new Server(server);

app.set('io', io);

app.use((req, res, next) => {
  res.set('X-Content-Type-Options', 'nosniff');
  res.set('X-Frame-Options', 'DENY');
  res.set('X-XSS-Protection', '1; mode=block');
  res.set('Referrer-Policy', 'strict-origin-when-cross-origin');
  res.set('Content-Security-Policy',
    "default-src 'self'; script-src 'self' 'unsafe-inline' 'unsafe-eval' https://webapi.amap.com https://restapi.amap.com https://unpkg.com; img-src 'self' data: https://*.is.autonavi.com https://*.tile.openstreetmap.org; style-src 'self' 'unsafe-inline' https://unpkg.com; connect-src 'self' https://restapi.amap.com wss: ws: https:");
  next();
});

const globalLimiter = rateLimit({
  windowMs: config.RATE_LIMIT_WINDOW_MS,
  max: config.RATE_LIMIT_MAX_REQUESTS,
  standardHeaders: true,
  legacyHeaders: false,
  message: { error: '请求过于频繁，请稍后再试' },
});
app.use('/api/', globalLimiter);

const loginLimiter = rateLimit({
  windowMs: config.RATE_LIMIT_WINDOW_MS,
  max: config.RATE_LIMIT_LOGIN_MAX,
  standardHeaders: true,
  legacyHeaders: false,
  message: { error: '登录请求过于频繁，请稍后再试' },
});
app.use('/api/login', loginLimiter);

const locationLimiter = rateLimit({
  windowMs: config.RATE_LIMIT_WINDOW_MS,
  max: config.LOCATION_RATE_LIMIT_MAX,
  standardHeaders: true,
  legacyHeaders: false,
  message: { error: '位置查询请求过于频繁' },
  keyGenerator: (req) => req.userId || req.ip,
});
app.use('/api/users/:userId/locations', locationLimiter);

app.use(express.static(path.join(__dirname, 'public')));
app.use('/uploads', express.static(path.join(__dirname, 'uploads')));
app.use(express.json({ limit: '10mb' }));

registerRoutes(app);

app.get('/health', (req, res) => {
  res.json({
    status: 'ok',
    uptime: process.uptime(),
    db: !!db.getDbInstance(),
    onlineCount: require('./socket/handler').onlineUsers.size,
    memoryUsage: process.memoryUsage(),
  });
});

registerSocketHandlers(io);

db.setSessionKickCallback((userId, oldTokens) => {
  const { onlineUsers } = require('./socket/handler');
  const tokenSet = new Set(oldTokens);
  for (const [socketId, info] of onlineUsers.entries()) {
    if (info.userId === userId && tokenSet.has(info.token)) {
      console.log(`[互踢] 用户 ${userId} 在新设备登录，踢掉旧 socket ${socketId}`);
      io.to(socketId).emit('force_logout', { reason: '账号已在其他设备登录' });
    }
  }
});

db.initDB().then(() => {
  initAuth();
  db.cleanExpiredSessions();
  db.startCleanupSchedule(); // 启动定时数据清理
  checkAlive();
  startAliveCheck();
  startStayTimeoutCleanup();
  startShareCleanup();
  setInterval(checkGeocodeRefreshSchedule, 3600000);

  const proto = useHttps ? 'https' : 'http';
  server.listen(config.PORT, config.HOST, () => {
    console.log(`\n  FamilyMap 位置共享服务已启动`);
    console.log(`  本地访问: ${proto}://localhost:${config.PORT}`);
    console.log(`  局域网: ${proto}://<IP>:${config.PORT}`);
    console.log(`  逆地理解码: ${config.AMAP_KEY ? '已配置高德Key' : '未配置(使用坐标降级)'}`);
    console.log(`  安全头: 已启用`);
    console.log(`  Rate Limit: 全局${config.RATE_LIMIT_MAX_REQUESTS}/min, 登录${config.RATE_LIMIT_LOGIN_MAX}/min`);
    console.log(`  bcrypt rounds: ${config.BCRYPT_ROUNDS}\n`);
  });
}).catch(err => { console.error('DB初始化失败:', err); process.exit(1); });
