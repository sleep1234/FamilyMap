const express = require('express');
const router = express.Router();
const { queryOne, queryAll, run, getDistance } = require('../db');
const { requireAuth, requireUserAccess } = require('../middleware/auth');
const { validateQuery, schemas } = require('../middleware/validate');

router.get('/api/eta', requireAuth, (req, res) => {
  const { fromLat, fromLng, toLat, toLng, speed } = req.query;
  if (!fromLat || !fromLng || !toLat || !toLng) return res.status(400).json({ error: '参数不完整' });
  const dist = getDistance(parseFloat(fromLat), parseFloat(fromLng), parseFloat(toLat), parseFloat(toLng));
  const spd = parseFloat(speed) || 5;
  const etaSeconds = Math.round(dist / Math.max(spd, 0.5));
  res.json({ 
    distance: Math.round(dist), 
    distanceKm: Math.round(dist / 100) / 10, // 保留1位小数的公里数
    etaSeconds, 
    etaMinutes: Math.round(etaSeconds / 60) 
  });
});

router.get('/api/users/:userId/world', requireAuth, requireUserAccess, (req, res) => {
  const locations = queryAll('SELECT DISTINCT ROUND(latitude, 3) as lat_key, ROUND(longitude, 3) as lng_key FROM locations WHERE user_id = ?', [req.params.userId]);
  const gridRows = queryAll('SELECT DISTINCT CAST(ROUND(latitude, 1) * 10 AS INTEGER) as lat_grid, CAST(ROUND(longitude, 1) * 10 AS INTEGER) as lng_grid FROM locations WHERE user_id = ?', [req.params.userId]);
  const cities = new Set();
  locations.forEach(l => {
    const addr = queryOne('SELECT address FROM geocode_cache WHERE lat_key = ? AND lng_key = ?', [l.lat_key.toFixed(3), l.lng_key.toFixed(3)]);
    if (addr?.address) {
      const match = addr.address.match(/市([^区县市]+[区县市])/);
      if (match) cities.add(match[1]);
    }
  });
  // 返回网格坐标供前端绘制迷雾遮罩
  const grids = gridRows.map(r => ({
    lat: r.lat_grid / 10,
    lng: r.lng_grid / 10,
  }));
  res.json({ gridCount: gridRows.length, cities: [...cities], cityCount: cities.size, grids });
});

router.get('/api/users/:userId/driving-score', requireAuth, requireUserAccess, (req, res) => {
  const days = parseInt(req.query.days) || 7;
  const daysParam = Math.min(Math.max(parseInt(req.query.days) || 7, 1), 365);
  const rows = queryAll(
    `SELECT speed, recorded_at FROM locations
     WHERE user_id = ? AND speed > 0 AND recorded_at >= datetime('now', '-' || ? || ' days')
     ORDER BY recorded_at ASC`,
    [req.params.userId, daysParam]
  );

  if (rows.length < 5) {
    return res.json({ days, score: null, message: '数据不足，需要更多行驶记录' });
  }

  let totalPoints = rows.length;
  let speedingCount = 0;
  let hardBrakeCount = 0;
  let highSpeedCount = 0;
  let totalSpeed = 0;
  let maxSpeed = 0;

  for (let i = 0; i < rows.length; i++) {
    const spd = rows[i].speed || 0;
    totalSpeed += spd;
    if (spd > maxSpeed) maxSpeed = spd;
    if (spd > 33.3) speedingCount++;
    if (spd > 22.2) highSpeedCount++;
    if (i > 0) {
      const prev = rows[i - 1].speed || 0;
      if (prev > 15 && spd < 5) hardBrakeCount++;
    }
  }

  const avgSpeed = totalSpeed / totalPoints;
  const speedingRate = speedingCount / totalPoints;
  const hardBrakeRate = hardBrakeCount / totalPoints;

  let score = 100;
  score -= speedingRate * 200;
  score -= hardBrakeRate * 500;
  score -= Math.max(0, (avgSpeed - 15) * 1.5);
  score = Math.max(0, Math.min(100, Math.round(score)));

  let grade, gradeColor;
  if (score >= 90) { grade = 'A'; gradeColor = '#10B981'; }
  else if (score >= 75) { grade = 'B'; gradeColor = '#3B82F6'; }
  else if (score >= 60) { grade = 'C'; gradeColor = '#F59E0B'; }
  else { grade = 'D'; gradeColor = '#EF4444'; }

  res.json({
    days, score, grade, gradeColor, totalRecords: totalPoints,
    avgSpeedKmh: Math.round(avgSpeed * 3.6 * 10) / 10,
    maxSpeedKmh: Math.round(maxSpeed * 3.6 * 10) / 10,
    speedingCount, hardBrakeCount, highSpeedCount,
  });
});

module.exports = router;
