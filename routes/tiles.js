const express = require('express');
const router = express.Router();
const fs = require('fs');
const path = require('path');
const https = require('https');
const http = require('http');

const TILE_CACHE_DIR = path.join(__dirname, '..', 'tiles_cache');

const A_MAP_URLS = [
  'https://webrd0{s}.is.autonavi.com/appmaptile?lang=zh_cn&size=1&scale=1&style=8&x={x}&y={y}&z={z}',
];

const downloading = new Map();

function fetchTile(z, x, y) {
  const key = `${z}/${x}/${y}`;
  if (downloading.has(key)) return downloading.get(key);

  const promise = new Promise((resolve, reject) => {
    const url = A_MAP_URLS[0]
      .replace('{s}', String((x + y) % 4 + 1))
      .replace('{x}', x).replace('{y}', y).replace('{z}', z);

    const req = https.get(url, {
      headers: {
        'User-Agent': 'Mozilla/5.0',
        'Referer': 'https://www.amap.com/',
      },
      timeout: 10000,
    }, (res) => {
      if (res.statusCode !== 200) {
        res.resume();
        return reject(new Error(`HTTP ${res.statusCode}`));
      }
      const chunks = [];
      res.on('data', c => chunks.push(c));
      res.on('end', () => {
        const buf = Buffer.concat(chunks);
        if (buf.length < 100) return reject(new Error('Tile too small'));
        const tilePath = path.join(TILE_CACHE_DIR, String(z), String(x), `${y}.png`);
        fs.mkdirSync(path.dirname(tilePath), { recursive: true });
        fs.writeFileSync(tilePath, buf);
        resolve(buf);
      });
      res.on('error', reject);
    });
    req.on('error', reject);
    req.on('timeout', () => { req.destroy(); reject(new Error('timeout')); });
  });

  promise.finally(() => downloading.delete(key));
  downloading.set(key, promise);
  return promise;
}

router.get('/api/tiles/:z/:x/:y', (req, res) => {
  const z = parseInt(req.params.z);
  const x = parseInt(req.params.x);
  const y = parseInt(req.params.y);

  if (isNaN(z) || isNaN(x) || isNaN(y) || z < 3 || z > 19) {
    return res.status(400).json({ error: 'invalid tile coords' });
  }

  const tilePath = path.join(TILE_CACHE_DIR, String(z), String(x), `${y}.png`);

  if (fs.existsSync(tilePath)) {
    const data = fs.readFileSync(tilePath);
    res.set('Content-Type', 'image/png');
    res.set('Cache-Control', 'public, max-age=604800');
    return res.send(data);
  }

  fetchTile(z, x, y).then(buf => {
    res.set('Content-Type', 'image/png');
    res.set('Cache-Control', 'public, max-age=604800');
    res.send(buf);
  }).catch(err => {
    res.status(502).json({ error: 'tile fetch failed', detail: err.message });
  });
});

router.get('/api/tiles/stats', (req, res) => {
  let count = 0;
  let size = 0;
  if (fs.existsSync(TILE_CACHE_DIR)) {
    const walk = (dir) => {
      if (!fs.existsSync(dir)) return;
      for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
        const p = path.join(dir, entry.name);
        if (entry.isDirectory()) walk(p);
        else { count++; size += fs.statSync(p).size; }
      }
    };
    walk(TILE_CACHE_DIR);
  }
  res.json({ count, sizeMB: Math.round(size / 1024 / 1024) });
});

module.exports = router;
