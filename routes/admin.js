const express = require('express');
const router = express.Router();
const config = require('../config');
const { queryOne, queryAll, run } = require('../db');
const { requireAuth } = require('../middleware/auth');
const { reverseGeocode, refreshGeocodeCacheBatch } = require('../services/geocode');

router.post('/api/admin/refresh-geocode-cache', requireAuth, async (req, res) => {
  const limit = parseInt(req.query.limit) || 500;
  const CACHE_FRESH_DAYS = config.CACHE_FRESH_DAYS;
  const expired = queryAll(
    `SELECT id, lat_key, lng_key FROM geocode_cache
     WHERE cached_at IS NULL OR cached_at < datetime('now', '-${CACHE_FRESH_DAYS} days')
     ORDER BY cached_at ASC LIMIT ?`, [limit]
  );
  if (expired.length === 0) {
    return res.json({ refreshed: 0, message: '没有需要刷新的缓存（90天内全部最新）' });
  }
  let refreshed = 0;
  let failed = 0;
  for (const item of expired) {
    try {
      const lat = parseFloat(item.lat_key);
      const lng = parseFloat(item.lng_key);
      const result = await reverseGeocode(lat, lng, { forceRefresh: true });
      if (result.address && !result.address.includes('位置(')) {
        refreshed++;
      } else {
        failed++;
      }
      await new Promise(r => setTimeout(r, 200));
    } catch (e) { failed++; }
  }
  res.json({ refreshed, failed, total: expired.length, message: `刷新完成：${refreshed} 成功，${failed} 失败` });
});

router.get('/api/admin/geocode-stats', requireAuth, (req, res) => {
  const CACHE_FRESH_DAYS = config.CACHE_FRESH_DAYS;
  const CACHE_STALE_DAYS = config.CACHE_STALE_DAYS;
  const total = queryOne('SELECT COUNT(*) as count FROM geocode_cache');
  const fresh = queryOne(
    `SELECT COUNT(*) as count FROM geocode_cache WHERE cached_at >= datetime('now', '-${CACHE_FRESH_DAYS} days')`
  );
  const stale = queryOne(
    `SELECT COUNT(*) as count FROM geocode_cache
     WHERE cached_at IS NOT NULL AND cached_at >= datetime('now', '-${CACHE_STALE_DAYS} days')
       AND cached_at < datetime('now', '-${CACHE_FRESH_DAYS} days')`
  );
  const mustRefresh = queryOne(
    `SELECT COUNT(*) as count FROM geocode_cache
     WHERE cached_at IS NULL OR cached_at < datetime('now', '-${CACHE_STALE_DAYS} days')`
  );
  const oldest = queryOne(
    'SELECT cached_at FROM geocode_cache WHERE cached_at IS NOT NULL ORDER BY cached_at ASC LIMIT 1'
  );
  const newest = queryOne(
    'SELECT cached_at FROM geocode_cache WHERE cached_at IS NOT NULL ORDER BY cached_at DESC LIMIT 1'
  );
  res.json({
    totalEntries: total.count,
    freshEntries: fresh.count,
    staleEntries: stale.count,
    expiredEntries: mustRefresh.count,
    freshDays: CACHE_FRESH_DAYS,
    staleDays: CACHE_STALE_DAYS,
    oldestCached: oldest?.cached_at || null,
    newestCached: newest?.cached_at || null,
  });
});

module.exports = router;
