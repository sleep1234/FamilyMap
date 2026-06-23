const initSqlJs = require('sql.js');
const fs = require('fs');

async function main() {
  const SQL = await initSqlJs();
  const buf = fs.readFileSync('./familymap.db');
  const db = new SQL.Database(buf);

  // 查看周鸿鹏最近的停留记录（包含home类型）
  const stays = db.exec(
    "SELECT s.stay_type, s.address, s.started_at, s.ended_at, s.duration_minutes, s.latitude, s.longitude " +
    "FROM stays s WHERE s.user_id = 'u_mqdneb32sg8c3' " +
    "ORDER BY s.started_at DESC LIMIT 20"
  );

  console.log('--- 周鸿鹏最近停留记录 ---');
  if (stays.length > 0) {
    const cols = stays[0].columns;
    stays[0].values.forEach(v => {
      const obj = {};
      cols.forEach((c, i) => obj[c] = v[i]);
      console.log(`${obj.started_at} ~ ${obj.ended_at || '进行中'} | ${obj.stay_type} | ${obj.duration_minutes || '-'}min | ${obj.address || '-'}`);
    });
  }

  // 查看home:status事件
  const homeStatus = db.exec(
    "SELECT * FROM stays s WHERE s.user_id = 'u_mqdneb32sg8c3' AND s.stay_type = 'home' " +
    "ORDER BY s.started_at DESC LIMIT 10"
  );

  console.log('\n--- 周鸿鹏home停留记录 ---');
  if (homeStatus.length > 0) {
    const cols = homeStatus[0].columns;
    homeStatus[0].values.forEach(v => {
      const obj = {};
      cols.forEach((c, i) => obj[c] = v[i]);
      console.log(`${obj.started_at} ~ ${obj.ended_at || '进行中'} | ${obj.duration_minutes || '-'}min`);
    });
  }

  // 查看最近位置，看是否在home边界
  const locations = db.exec(
    "SELECT l.latitude, l.longitude, l.speed, l.accuracy, l.recorded_at " +
    "FROM locations l WHERE l.user_id = 'u_mqdneb32sg8c3' " +
    "ORDER BY l.recorded_at DESC LIMIT 30"
  );

  console.log('\n--- 周鸿鹏最近位置 ---');
  if (locations.length > 0) {
    const cols = locations[0].columns;
    locations[0].values.forEach(v => {
      const obj = {};
      cols.forEach((c, i) => obj[c] = v[i]);
      console.log(`${obj.recorded_at} | ${obj.latitude},${obj.longitude} | spd=${obj.speed} | acc=${obj.accuracy}`);
    });
  }

  db.close();
}
main().catch(e => console.error(e));
