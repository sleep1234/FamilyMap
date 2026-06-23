const https = require('https');
const config = require('../config');
const { queryOne, queryAll, run, boundedSet } = require('../db');

const AMAP_KEY = config.AMAP_KEY;
const CACHE_FRESH_DAYS = config.CACHE_FRESH_DAYS;
const CACHE_STALE_DAYS = config.CACHE_STALE_DAYS;

const _geocodeLastCall = new Map();
const _refreshingKeys = new Set();

function wgs84ToGcj02(wgsLat, wgsLng) {
  const a = 6378245.0;
  const ee = 0.00669342162296594323;
  if (wgsLng < 72.004 || wgsLng > 137.8347 || wgsLat < 0.8293 || wgsLat > 55.8271) return { lat: wgsLat, lng: wgsLng };
  const dLat = _transformLat(wgsLng - 105.0, wgsLat - 35.0);
  const dLng = _transformLng(wgsLng - 105.0, wgsLat - 35.0);
  const radLat = wgsLat / 180.0 * Math.PI;
  let magic = Math.sin(radLat);
  magic = 1 - ee * magic * magic;
  const sqrtMagic = Math.sqrt(magic);
  const lat = wgsLat + (dLat * 180.0) / ((a * (1 - ee)) / (magic * sqrtMagic) * Math.PI);
  const lng = wgsLng + (dLng * 180.0) / (a / sqrtMagic * Math.cos(radLat) * Math.PI);
  return { lat, lng };
}

function _transformLat(x, y) {
  let ret = -100.0 + 2.0 * x + 3.0 * y + 0.2 * y * y + 0.1 * x * y + 0.2 * Math.sqrt(Math.abs(x));
  ret += (20.0 * Math.sin(6.0 * x * Math.PI) + 20.0 * Math.sin(2.0 * x * Math.PI)) * 2.0 / 3.0;
  ret += (20.0 * Math.sin(y * Math.PI) + 40.0 * Math.sin(y / 3.0 * Math.PI)) * 2.0 / 3.0;
  ret += (160.0 * Math.sin(y / 12.0 * Math.PI) + 320 * Math.sin(y * Math.PI / 30.0)) * 2.0 / 3.0;
  return ret;
}

function _transformLng(x, y) {
  let ret = 300.0 + x + 2.0 * y + 0.1 * x * x + 0.1 * x * y + 0.1 * Math.sqrt(Math.abs(x));
  ret += (20.0 * Math.sin(6.0 * x * Math.PI) + 20.0 * Math.sin(2.0 * x * Math.PI)) * 2.0 / 3.0;
  ret += (20.0 * Math.sin(x * Math.PI) + 40.0 * Math.sin(x / 3.0 * Math.PI)) * 2.0 / 3.0;
  ret += (150.0 * Math.sin(x / 12.0 * Math.PI) + 300.0 * Math.sin(x / 30.0 * Math.PI)) * 2.0 / 3.0;
  return ret;
}

async function reverseGeocode(lat, lng, { forceRefresh = false } = {}) {
  const latKey = lat.toFixed(3);
  const lngKey = lng.toFixed(3);
  const cached = queryOne('SELECT * FROM geocode_cache WHERE lat_key = ? AND lng_key = ?', [latKey, lngKey]);

  if (cached && !forceRefresh) {
    const ageDays = cached.cached_at
      ? (Date.now() - new Date(cached.cached_at + 'Z').getTime()) / 86400000
      : 999;
    if (ageDays < CACHE_FRESH_DAYS) {
      return { address: cached.address, formatted: cached.formatted };
    }
    if (ageDays < CACHE_STALE_DAYS) {
      _backgroundRefresh(lat, lng, latKey, lngKey, cached);
      return { address: cached.address, formatted: cached.formatted };
    }
  }

  if (!AMAP_KEY) {
    const fallback = `${lat.toFixed(4)},${lng.toFixed(4)}(坐标)`;
    return { address: fallback, formatted: fallback };
  }

  const gcj = wgs84ToGcj02(lat, lng);

  return new Promise((resolve) => {
    const url = `https://restapi.amap.com/v3/geocode/regeo?key=${AMAP_KEY}&location=${gcj.lng},${gcj.lat}&extensions=base`;
    const req = https.get(url, { timeout: 5000 }, (res) => {
      let data = '';
      res.on('data', chunk => data += chunk);
      res.on('end', () => {
        try {
          const json = JSON.parse(data);
          const fallbackAddr = `位置(${lat.toFixed(2)},${lng.toFixed(2)})`;
          if (json.status !== '1') {
            resolve({ address: fallbackAddr, formatted: '' });
            return;
          }
          const address = json.regeocode?.formatted_address || fallbackAddr;
          const comp = json.regeocode?.addressComponent || {};
          const formatted = comp.township || comp.street || comp.district ||
            address.split('区').pop()?.substring(0, 20) || address;
          if (cached) {
            run('UPDATE geocode_cache SET address = ?, formatted = ?, cached_at = datetime("now") WHERE lat_key = ? AND lng_key = ?',
              [address, formatted, latKey, lngKey]);
          } else {
            run('INSERT INTO geocode_cache (lat_key, lng_key, address, formatted) VALUES (?, ?, ?, ?)',
              [latKey, lngKey, address, formatted]);
          }
          resolve({ address, formatted, precision: address.length > 20 ? 'high' : 'low' });
        } catch (e) {
          resolve({ address: `位置(${lat.toFixed(2)},${lng.toFixed(2)})`, formatted: '' });
        }
      });
    });
    req.on('error', () => resolve({ address: `位置(${lat.toFixed(2)},${lng.toFixed(2)})`, formatted: '' }));
    req.on('timeout', () => { req.destroy(); resolve({ address: `位置(${lat.toFixed(2)},${lng.toFixed(2)})`, formatted: '' }); });
  });
}

function _backgroundRefresh(lat, lng, latKey, lngKey, cached) {
  const lockKey = `${latKey},${lngKey}`;
  if (_refreshingKeys.has(lockKey)) return;
  _refreshingKeys.add(lockKey);
  reverseGeocode(lat, lng, { forceRefresh: true })
    .then(result => {
      if (result.address && !result.address.includes('位置(')) {
        run('UPDATE geocode_cache SET address = ?, formatted = ?, cached_at = datetime("now") WHERE lat_key = ? AND lng_key = ?',
          [result.address, result.formatted || '', latKey, lngKey]);
      }
    })
    .catch(() => { })
    .finally(() => _refreshingKeys.delete(lockKey));
}

function setGeocodeThrottle(userId, now) {
  boundedSet(_geocodeLastCall, userId, now);
}

function getGeocodeLastCall(userId) {
  return _geocodeLastCall.get(userId) || 0;
}

let _lastRefreshDate = '';

function checkGeocodeRefreshSchedule() {
  const now = new Date();
  if (now.getDate() === config.GEOCODE_REFRESH_DAY && now.getHours() === config.GEOCODE_REFRESH_HOUR) {
    const today = now.toISOString().split('T')[0];
    if (_lastRefreshDate === today) return;
    _lastRefreshDate = today;
    console.log(`[定时刷新] 开始刷新逆编码缓存（超过${CACHE_FRESH_DAYS}天）...`);
    refreshGeocodeCacheBatch(config.GEOCODE_REFRESH_LIMIT);
  }
}

async function refreshGeocodeCacheBatch(limit) {
  const expired = queryAll(
    `SELECT id, lat_key, lng_key FROM geocode_cache
     WHERE cached_at IS NULL OR cached_at < datetime('now', '-${CACHE_FRESH_DAYS} days')
     ORDER BY cached_at ASC LIMIT ?`, [limit]
  );
  if (expired.length === 0) {
    console.log('[定时刷新] 没有过期缓存');
    return;
  }
  console.log(`[定时刷新] 找到 ${expired.length} 条过期缓存，开始刷新...`);
  let ok = 0, fail = 0;
  for (const item of expired) {
    try {
      const lat = parseFloat(item.lat_key);
      const lng = parseFloat(item.lng_key);
      await reverseGeocode(lat, lng, { forceRefresh: true });
      ok++;
      await new Promise(r => setTimeout(r, 200));
    } catch (e) { fail++; }
  }
  console.log(`[定时刷新] 完成：${ok} 成功，${fail} 失败`);
}

module.exports = {
  wgs84ToGcj02, reverseGeocode,
  setGeocodeThrottle, getGeocodeLastCall,
  _geocodeLastCall,
  checkGeocodeRefreshSchedule, refreshGeocodeCacheBatch,
};
