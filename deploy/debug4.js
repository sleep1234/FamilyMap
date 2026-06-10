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

  // 1. Stop pm2 completely
  console.log('Stopping pm2...');
  await ssh.execCommand('pm2 stop familymap');
  await ssh.execCommand('pm2 delete familymap');

  // 2. Delete any left DB files
  await ssh.execCommand(`find ${remotePath} -name "*.db" -delete`);

  // 3. Run server.js directly with node (without pm2) to see the actual error
  console.log('Running server.js directly...');
  const r = await ssh.execCommand(`cd ${remotePath} && timeout 5 node server.js 2>&1 || true`);
  console.log('Output:', r.stdout);
  console.log('Error:', r.stderr);

  await ssh.dispose();
}

main().catch(console.error);
