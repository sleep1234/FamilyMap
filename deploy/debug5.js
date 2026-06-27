const { NodeSSH } = require('node-ssh');
const ssh = new NodeSSH();

async function main() {
  await ssh.connect({
    host: 'www.zhp98.fun',
    port: 22,
    username: 'root',
    password: 'Zhp199802!'
  });

  const remotePath = '/vol1/1000/9自己的软件项目/家庭位置共享';

  // 1. Flush pm2 logs (clear old logs)
  console.log('Flushing pm2 logs...');
  await ssh.execCommand('pm2 flush');

  // 2. Restart the process
  console.log('Restarting familymap...');
  await ssh.execCommand(`pm2 restart familymap`);

  // 3. Wait for startup
  await new Promise(resolve => setTimeout(resolve, 5000));

  // 4. Check NEW logs only (fresh after flush)
  console.log('\n--- Fresh PM2 Logs ---');
  let r = await ssh.execCommand('pm2 logs familymap --lines 20 --nostream');
  console.log('OUT:', r.stdout);
  console.log('ERR:', r.stderr);

  // 5. Check process status
  r = await ssh.execCommand('pm2 describe familymap');
  console.log('\n--- Process Info ---');
  // Extract key info
  const lines = r.stdout.split('\n');
  const keyFields = ['status', 'restarts', 'exec cwd', 'script path', 'exec mode'];
  lines.forEach(line => {
    if (keyFields.some(f => line.includes(f))) console.log(line.trim());
  });

  // 6. Test API
  console.log('\n--- API Tests ---');
  r = await ssh.execCommand('curl -s http://localhost:8090/api/users');
  console.log('GET /api/users:', r.stdout?.substring(0, 300));

  r = await ssh.execCommand('curl -s -X POST http://localhost:8090/api/users -H "Content-Type: application/json" -d \'{"name":"test_user"}\'');
  console.log('POST /api/users:', r.stdout?.substring(0, 300));

  await ssh.dispose();
}

main().catch(console.error);
