const express = require('express');
const router = express.Router();
const rateLimit = require('express-rate-limit');
const config = require('../config');
const { queryOne, escapeHtml } = require('../db');
const { requireAuth } = require('../middleware/auth');
const { validateBody, schemas } = require('../middleware/validate');
const { wgs84ToGcj02 } = require('../services/geocode');
const { createShareToken, getShareData, getShareLocation } = require('../services/share');

const shareApiLimiter = rateLimit({
  windowMs: config.RATE_LIMIT_WINDOW_MS,
  max: 30,
  standardHeaders: true,
  legacyHeaders: false,
  message: { error: '请求过于频繁，请稍后再试' },
});

router.post('/api/share-link', requireAuth, validateBody(schemas.shareLink), (req, res) => {
  const userId = req.userId;
  const { latitude, longitude, durationMinutes, trackMode } = req.body;
  if (!latitude || !longitude) return res.status(400).json({ error: '参数不完整' });
  const result = createShareToken(userId, latitude, longitude, durationMinutes, trackMode);
  const proto = req.protocol || 'http';
  const host = req.get('host') || `www.zhp98.fun`;
  res.json({
    token: result.token,
    url: `${proto}://${host}/share/${result.token}`,
    expiresAt: new Date(result.expiresAt).toISOString()
  });
});

router.get('/share/:token', shareApiLimiter, (req, res) => {
  const data = getShareData(req.params.token);
  if (!data) {
    return res.status(404).send(`<!DOCTYPE html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>链接已过期</title><style>body{font-family:-apple-system,BlinkMacSystemFont,sans-serif;display:flex;justify-content:center;align-items:center;height:100vh;margin:0;background:#f1f5f9;color:#64748b}</style></head><body><div style="text-align:center"><h2>链接已过期或不存在</h2><p>请向分享者索要新的链接</p></div></body></html>`);
  }
  const user = queryOne('SELECT name, avatar_color FROM users WHERE id = ?', [data.userId]);
  const gcjCoords = getShareLocation(data);

  res.send(`<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no">
<title>${escapeHtml(user?.name) || '家人'}的位置 - FamilyMap</title>
<link rel="stylesheet" href="https://unpkg.com/leaflet@1.9.4/dist/leaflet.css"/>
<script src="https://unpkg.com/leaflet@1.9.4/dist/leaflet.js"></script>
<style>
*{margin:0;padding:0;box-sizing:border-box}
body{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI','PingFang SC',sans-serif;background:#0f172a;color:#e2e8f0;height:100vh;display:flex;flex-direction:column}
.header{padding:16px 20px;background:#1e293b;display:flex;align-items:center;gap:12px;border-bottom:1px solid #334155;z-index:1000}
.avatar{width:40px;height:40px;border-radius:50%;display:flex;align-items:center;justify-content:center;font-size:18px;font-weight:700;color:#fff}
.name{font-size:16px;font-weight:600}
.status{font-size:12px;color:#94a3b8}
.mode-tag{font-size:11px;background:#3b82f6;color:#fff;padding:2px 8px;border-radius:10px;margin-left:8px}
#map{flex:1;width:100%;z-index:1}
.info-bar{padding:12px 20px;background:#1e293b;border-top:1px solid #334155;font-size:13px;color:#94a3b8;text-align:center;z-index:1000}
.expired{display:none;padding:20px;text-align:center;color:#ef4444;background:#1e293b;z-index:1000}
.leaflet-popup-content-wrapper{background:#1e293b;color:#e2e8f0;border-radius:10px}
.leaflet-popup-tip{background:#1e293b}
.person-marker{display:flex;flex-direction:column;align-items:center}
.person-dot{width:42px;height:42px;border-radius:50%;display:flex;align-items:center;justify-content:center;font-size:18px;font-weight:700;color:#fff;box-shadow:0 2px 10px rgba(0,0,0,.4);border:3px solid #fff}
.person-name{margin-top:4px;background:rgba(30,41,59,.9);color:#fff;padding:2px 8px;border-radius:4px;font-size:11px;font-weight:500;white-space:nowrap}
</style>
</head>
<body>
<div class="header">
  <div class="avatar" style="background:${user?.avatar_color || '#3b82f6'}">${escapeHtml((user?.name || '?')[0])}</div>
  <div><div class="name">${escapeHtml(user?.name) || '未知'}${data.trackMode ? '<span class="mode-tag">行程追踪中</span>' : ''}</div><div class="status">位置分享</div></div>
</div>
<div id="map"></div>
<div class="info-bar" id="info">加载地图中...</div>
<div class="expired" id="expired">链接已过期，请向分享者索要新的链接</div>
<script>
var lat0=${gcjCoords.lat},lng0=${gcjCoords.lng},token=${JSON.stringify(req.params.token)},trackMode=${data.trackMode ? 'true' : 'false'},expiresAt=${data.expires};
var userName=${JSON.stringify(escapeHtml(user?.name) || '家人')},userColor=${JSON.stringify(user?.avatar_color || '#3b82f6')};
var map=L.map('map',{zoomControl:false,attributionControl:false}).setView([lat0,lng0],16);
L.control.zoom({position:'topright'}).addTo(map);
L.tileLayer('https://webrd0{s}.is.autonavi.com/appmaptile?lang=zh_cn&size=1&scale=1&style=8&x={x}&y={y}&z={z}',{
  subdomains:['1','2','3','4'],maxZoom:18
}).addTo(map);
var icon=L.divIcon({className:'',html:'<div class="person-marker"><div class="person-dot" style="background:'+userColor+'">'+userName.charAt(0)+'</div><div class="person-name">'+userName+'</div></div>',iconSize:[50,70],iconAnchor:[25,55]});
var marker=L.marker([lat0,lng0],{icon:icon,zIndexOffset:1000}).addTo(map);
marker.bindPopup('<b>'+userName+'</b>');
document.getElementById('info').textContent='最后更新: '+new Date().toLocaleTimeString('zh-CN');
if(trackMode){setInterval(function(){
  if(Date.now()>expiresAt){document.getElementById('expired').style.display='block';document.getElementById('info').textContent='链接已过期';return}
  fetch('/api/share/'+token).then(function(r){return r.json()}).then(function(d){
    if(d.latitude&&d.longitude){marker.setLatLng([d.latitude,d.longitude]);map.setView([d.latitude,d.longitude]);
      document.getElementById('info').textContent='实时位置 · '+new Date().toLocaleTimeString('zh-CN')}
  }).catch(function(){})
},5000)}
</script>
</body>
</html>`);
});

router.get('/api/share/:token', shareApiLimiter, (req, res) => {
  const data = getShareData(req.params.token);
  if (!data) return res.status(404).json({ error: '链接已过期或不存在' });
  const user = queryOne('SELECT name, avatar_color FROM users WHERE id = ?', [data.userId]);
  const gcjCoords = getShareLocation(data);
  res.json({ name: user?.name, latitude: gcjCoords.lat, longitude: gcjCoords.lng, trackMode: !!data.trackMode });
});

module.exports = router;
