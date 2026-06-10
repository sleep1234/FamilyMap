const { NodeSSH } = require('node-ssh');
const ssh = new NodeSSH();

async function main() {
  await ssh.connect({
    host: 'www.zhp0104.fun',
    port: 22,
    username: 'root',
    password: 'Zhp199802!'
  });

  // Show the contacts table creation lines
  const result = await ssh.execCommand('grep -n -i "contacts" /vol1/1000/9自己的软件项目/家庭位置共享/server.js');
  console.log('GREP RESULTS:', result.stdout || result.stderr);

  // Show lines around the CREATE TABLE contacts statement
  const result2 = await ssh.execCommand('sed -n "40,75p" /vol1/1000/9自己的软件项目/家庭位置共享/server.js');
  console.log('SERVER.JS LINES 40-75:\n', result2.stdout);

  await ssh.dispose();
}

main().catch(console.error);
