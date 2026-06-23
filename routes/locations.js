const express = require('express');
const router = express.Router();
const { queryOne, queryAll, run, escapeXml, getDistance } = require('../db');
const { requireAuth, requireUserAccess } = require('../middleware/auth');
const { validateQuery, schemas } = require('../middleware/validate');
const { reverseGeocode } = require('../services/geocode');

router.get('/api/users/:userId/locations', requireAuth, requireUserAccess, validateQuery(schemas.queryHours), (req, res) => {
  const hours = Math.min(Math.max(parseInt(req.query.hours) || 24, 1), 720);
  const locations = queryAll(`SELECT * FROM locations
    WHERE user_id = ? AND recorded_at >= datetime('now', '-' || ? || ' hours') ORDER BY recorded_at ASC`,
    [req.params.userId, hours]);
  res.json(locations);
});

router.get('/api/geocode', requireAuth, async (req, res) => {
  const { lat, lng } = req.query;
  if (!lat || !lng) return res.status(400).json({ error: '参数不完整' });
  const result = await reverseGeocode(parseFloat(lat), parseFloat(lng));
  res.json(result);
});

router.get('/api/users/:userId/stays', requireAuth, requireUserAccess, validateQuery(schemas.queryDays), (req, res) => {
  const days = Math.min(Math.max(parseInt(req.query.days) || 7, 1), 365);
  const tz = parseInt(req.query.tz) || 8;
  const stays = queryAll(`SELECT * FROM stays WHERE user_id = ? AND datetime(started_at, '+${tz} hours') >= datetime('now', '-${days} days', '+${tz} hours') ORDER BY started_at DESC`,
    [req.params.userId]);
  res.json(stays);
});

router.get('/api/users/:userId/timeline', requireAuth, requireUserAccess, (req, res) => {
  const date = req.query.date || new Date().toISOString().split('T')[0];
  // 客户端传时区偏移（如中国=8），将 UTC 存储的时间转为本地时间再比较日期
  const tz = parseInt(req.query.tz) || 8;
  const stays = queryAll(
    `SELECT * FROM stays WHERE user_id = ? AND date(started_at, '+${tz} hours') = ? ORDER BY started_at ASC`,
    [req.params.userId, date]
  );
  res.json(stays);
});

router.get('/api/users/:userId/track', requireAuth, requireUserAccess, (req, res) => {
  const date = req.query.date || new Date().toISOString().split('T')[0];
  const tz = parseInt(req.query.tz) || 8;
  // 用本地时间边界，转为 UTC 做范围查询
  // 本地日期起始 = date -tz hours (UTC), 本地日期结束 = date+1 -tz hours (UTC)
  const startUtc = `${date} 00:00:00`;  // 本地起始
  const endUtc = `${date} 23:59:59`;    // 本地结束
  const points = queryAll(
    `SELECT id, latitude, longitude, speed, address, recorded_at FROM locations
     WHERE user_id = ? AND datetime(recorded_at, '+${tz} hours') >= ? AND datetime(recorded_at, '+${tz} hours') <= ?
     GROUP BY strftime('%Y-%m-%d %H:%M', recorded_at)
     ORDER BY recorded_at ASC`,
    [req.params.userId, `${date} 00:00:00`, `${date} 23:59:59`]
  );
  res.json(points);
});

router.get('/api/users/:userId/export/gpx', requireAuth, requireUserAccess, (req, res) => {
  const date = req.query.date || new Date().toISOString().split('T')[0];
  const tz = parseInt(req.query.tz) || 8;
  const points = queryAll(
    `SELECT latitude, longitude, speed, accuracy, recorded_at FROM locations
     WHERE user_id = ? AND datetime(recorded_at, '+${tz} hours') >= ? AND datetime(recorded_at, '+${tz} hours') <= ?
     ORDER BY recorded_at ASC`,
    [req.params.userId, `${date} 00:00:00`, `${date} 23:59:59`]
  );
  const user = queryOne('SELECT name FROM users WHERE id = ?', [req.params.userId]);
  const trkpts = points.map(p =>
    `    <trkpt lat="${p.latitude}" lon="${p.longitude}"><ele>0</ele><time>${new Date(p.recorded_at + 'Z').toISOString()}</time><speed>${p.speed || 0}</speed></trkpt>`
  ).join('\n');
  const gpx = `<?xml version="1.0" encoding="UTF-8"?>
<gpx version="1.1" creator="FamilyMap">
  <trk><name>${escapeXml(user?.name) || 'Unknown'} - ${date}</name>
  <trkseg>
${trkpts}
  </trkseg></trk>
</gpx>`;
  res.set('Content-Type', 'application/gpx+xml');
  res.set('Content-Disposition', `attachment; filename="familymap-${date}.gpx"`);
  res.send(gpx);
});

router.get('/api/users/:userId/heatmap', requireAuth, requireUserAccess, (req, res) => {
  const days = parseInt(req.query.days) || 7;
  const grid = new Map();
  const daysParam = Math.min(Math.max(parseInt(req.query.days) || 7, 1), 365);
  const rows = queryAll(
    `SELECT latitude, longitude FROM locations
     WHERE user_id = ? AND recorded_at >= datetime('now', '-' || ? || ' days')
       AND latitude IS NOT NULL AND longitude IS NOT NULL`,
    [req.params.userId, daysParam]
  );
  for (const r of rows) {
    const latG = (r.latitude * 1000 | 0) / 1000;
    const lngG = (r.longitude * 1000 | 0) / 1000;
    const key = `${latG},${lngG}`;
    if (grid.has(key)) {
      grid.get(key).count++;
    } else {
      grid.set(key, { lat: latG + 0.0005, lng: lngG + 0.0005, count: 1 });
    }
  }
  const points = [...grid.values()];
  const maxCount = Math.max(1, ...points.map(p => p.count));
  const result = points.map(p => ({
    lat: p.lat, lng: p.lng,
    intensity: Math.round((p.count / maxCount) * 100) / 100,
    count: p.count
  })).sort((a, b) => b.intensity - a.intensity);
  res.json({ days, totalPoints: rows.length, heatmap: result });
});

module.exports = router;
