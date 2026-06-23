const crypto = require('crypto');
const config = require('../config');
const { queryOne, queryAll, run, cleanExpiredShareTokens } = require('../db');
const { wgs84ToGcj02 } = require('./geocode');

function generateShareToken() {
  return crypto.randomBytes(config.SHARE_TOKEN_BYTES).toString('hex');
}

function createShareToken(userId, latitude, longitude, durationMinutes, trackMode) {
  cleanExpiredShareTokens();
  const token = generateShareToken();
  const maxDuration = Math.min(durationMinutes || config.SHARE_DEFAULT_DURATION_MINUTES, config.SHARE_MAX_DURATION_MINUTES);
  const expiresAt = Date.now() + maxDuration * 60000;
  run('INSERT INTO share_tokens (token, user_id, latitude, longitude, expires_at, track_mode) VALUES (?, ?, ?, ?, ?, ?)',
    [token, userId, latitude, longitude, expiresAt, trackMode ? 1 : 0]);
  return { token, expiresAt };
}

function getShareData(token) {
  const row = queryOne('SELECT * FROM share_tokens WHERE token = ?', [token]);
  if (!row) return null;
  if (row.expires_at < Date.now()) {
    run('DELETE FROM share_tokens WHERE token = ?', [token]);
    return null;
  }
  return {
    userId: row.user_id,
    latitude: row.latitude,
    longitude: row.longitude,
    expires: row.expires_at,
    trackMode: row.track_mode === 1,
  };
}

function getLatestShareLocation(userId, isGcj02) {
  const latest = queryOne('SELECT latitude, longitude FROM locations WHERE user_id = ? ORDER BY recorded_at DESC LIMIT 1', [userId]);
  if (!latest) return null;
  if (isGcj02) {
    return { lat: latest.latitude, lng: latest.longitude, isGcj02: false };
  }
  return { lat: latest.latitude, lng: latest.longitude, isGcj02: true };
}

function getShareLocation(data) {
  let lat = data.latitude, lng = data.longitude;
  let isGcj02 = true;
  if (data.trackMode) {
    const latest = queryOne('SELECT latitude, longitude FROM locations WHERE user_id = ? ORDER BY recorded_at DESC LIMIT 1', [data.userId]);
    if (latest) { lat = latest.latitude; lng = latest.longitude; isGcj02 = false; }
  }
  return isGcj02 ? { lat, lng } : wgs84ToGcj02(lat, lng);
}

function startCleanupInterval() {
  setInterval(cleanExpiredShareTokens, config.SHARE_CLEANUP_INTERVAL_MS || 3600000);
}

module.exports = {
  createShareToken, getShareData, getLatestShareLocation, getShareLocation,
  cleanExpiredShareTokens, startCleanupInterval,
};
