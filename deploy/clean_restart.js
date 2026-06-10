const { NodeSSH } = require('node-ssh');
const ssh = new NodeSSH();

async function main() {
  await ssh.connect({
    host: 'www.zhp0104.fun',
    port: 22,
    username: 'root',
    password: 'Zhp199802!'
  });

  const remotePath = '/vol1/1000/9自己的软件项目/家庭位置共享';

  // 1. Delete ALL database files
  console.log('Removing database files...');
  let r = await ssh.execCommand(`rm -f ${remotePath}/database.db ${remotePath}/*.db ${remotePath}/data/*.db`);
  console.log('DB remove result:', r.stdout || r.stderr || 'OK');

  // 2. Stop pm2 process
  console.log('Stopping pm2...');
  r = await ssh.execCommand('pm2 stop familymap');
  console.log('Stop result:', r.stdout || r.stderr);

  // 3. Restart pm2 process
  console.log('Starting pm2...');
  r = await ssh.execCommand(`cd ${remotePath} && pm2 start server.js --name familymap`);
  console.log('Start result:', r.stdout || r.stderr);

  // 4. Wait a moment for startup
  await new Promise(resolve => setTimeout(resolve, 3000));

  // 5. Check logs
  console.log('\n--- PM2 Logs ---');
  r = await ssh.execCommand('pm2 logs familymap --lines 15 --nostream');
  console.log(r.stdout || r.stderr);

  // 6. Check port
  console.log('\n--- Port Check ---');
  r = await ssh.execCommand('ss -tlnp | grep 8090');
  console.log(r.stdout || r.stderr || 'Port 8090 not listening!');

  // 7. Test API
  console.log('\n--- API Test ---');
  r = await ssh.execCommand('curl -s http://localhost:8090/api/circles');
  console.log(r.stdout || r.stderr);

  await ssh.dispose();
}

main().catch(console.error);
