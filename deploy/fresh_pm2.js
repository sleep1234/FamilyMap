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

  // 1. Completely flush pm2
  console.log('Flushing pm2...');
  let r = await ssh.execCommand('pm2 delete familymap 2>/dev/null; pm2 kill');
  console.log(r.stdout || r.stderr || 'pm2 killed');

  // Wait a moment
  await new Promise(resolve => setTimeout(resolve, 2000));

  // 2. Resurrect pm2 (fresh start)
  console.log('Starting fresh pm2...');
  r = await ssh.execCommand(`cd ${remotePath} && PORT=8090 pm2 start server.js --name familymap`);
  console.log(r.stdout || r.stderr);

  // 3. Wait for startup
  await new Promise(resolve => setTimeout(resolve, 4000));

  // 4. Check logs
  console.log('\n--- PM2 Logs ---');
  r = await ssh.execCommand('pm2 logs familymap --lines 10 --nostream');
  console.log(r.stdout);
  console.log(r.stderr);

  // 5. Check port
  console.log('\n--- Port Check ---');
  r = await ssh.execCommand('ss -tlnp | grep 8090');
  console.log(r.stdout || 'Port 8090 NOT listening');

  // 6. Test APIs
  console.log('\n--- API Test ---');
  r = await ssh.execCommand('curl -s http://localhost:8090/api/users');
  console.log('Users:', r.stdout?.substring(0, 200) || r.stderr);

  r = await ssh.execCommand('curl -s http://localhost:8090/api/circles');
  console.log('Circles:', r.stdout?.substring(0, 200) || r.stderr);

  // 7. Save pm2 config
  console.log('\n--- Saving pm2 config ---');
  r = await ssh.execCommand('pm2 save');
  console.log(r.stdout?.substring(0, 200));

  await ssh.dispose();
}

main().catch(console.error);
