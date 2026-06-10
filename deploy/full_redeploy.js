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

  // 1. Stop pm2 first
  console.log('Stopping pm2...');
  await ssh.execCommand('pm2 stop familymap');

  // 2. Delete ALL database files (including familymap.db)
  console.log('Removing ALL database files...');
  let r = await ssh.execCommand(`find ${remotePath} -name "*.db" -type f 2>/dev/null`);
  console.log('Found DB files:', r.stdout || 'none');
  r = await ssh.execCommand(`find ${remotePath} -name "*.db" -delete`);
  console.log('Deleted');

  // 3. Upload local server.js (the correct version)
  console.log('Uploading server.js...');
  await ssh.putFile('C:\\FamilyMap\\server.js', `${remotePath}/server.js`);
  console.log('server.js uploaded');

  // 4. Verify the uploaded file contacts table definition
  console.log('\nVerifying contacts table definition:');
  r = await ssh.execCommand(`sed -n '63,66p' ${remotePath}/server.js`);
  console.log(r.stdout);

  // 5. Also check DB_PATH in the uploaded file
  r = await ssh.execCommand(`grep "DB_PATH" ${remotePath}/server.js`);
  console.log('DB_PATH:', r.stdout);

  // 6. Restart pm2
  console.log('Restarting pm2...');
  r = await ssh.execCommand(`cd ${remotePath} && pm2 start server.js --name familymap`);
  console.log(r.stdout);

  // 7. Wait for startup
  await new Promise(resolve => setTimeout(resolve, 4000));

  // 8. Check logs
  console.log('\n--- PM2 Logs (last 20 lines) ---');
  r = await ssh.execCommand('pm2 logs familymap --lines 20 --nostream');
  console.log(r.stdout);
  console.log(r.stderr);

  // 9. Test API
  console.log('\n--- API Test: /api/users ---');
  r = await ssh.execCommand('curl -s http://localhost:8090/api/users');
  console.log(r.stdout || r.stderr);

  await ssh.dispose();
}

main().catch(console.error);
