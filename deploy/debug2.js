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

  // Show exact raw bytes around line 63
  console.log('=== Lines 60-70 with cat -A (shows hidden chars) ===');
  let r = await ssh.execCommand(`sed -n '60,70p' ${remotePath}/server.js | cat -A`);
  console.log(r.stdout);

  // Also check if there's another CREATE TABLE contacts elsewhere
  console.log('=== All CREATE TABLE lines ===');
  r = await ssh.execCommand(`grep -n "CREATE TABLE" ${remotePath}/server.js`);
  console.log(r.stdout);

  // Check for PRIMARY KEY occurrences
  console.log('=== All PRIMARY KEY lines ===');
  r = await ssh.execCommand(`grep -n "PRIMARY KEY" ${remotePath}/server.js`);
  console.log(r.stdout);

  await ssh.dispose();
}

main().catch(console.error);
