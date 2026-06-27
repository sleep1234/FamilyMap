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

  // 1. Upload updated server.js
  console.log('Uploading server.js...');
  await ssh.putFile('C:\\FamilyMap\\server.js', `${remotePath}/server.js`);
  console.log('server.js uploaded');

  // 2. Restart pm2
  console.log('Restarting pm2...');
  let r = await ssh.execCommand('pm2 restart familymap');
  console.log(r.stdout?.substring(0, 200));

  // 3. Wait for startup
  await new Promise(resolve => setTimeout(resolve, 4000));

  // 4. Verify
  r = await ssh.execCommand('pm2 logs familymap --lines 5 --nostream');
  console.log('\n--- Logs ---');
  console.log(r.stdout);

  r = await ssh.execCommand('curl -s -X POST http://localhost:8090/api/circles/join -H "Content-Type: application/json" -d \'{"inviteCode":"TEST01","userId":"u_test99"}\'');
  console.log('API test:', r.stdout?.substring(0, 200) || r.stderr);

  await ssh.dispose();
}

main().catch(console.error);
