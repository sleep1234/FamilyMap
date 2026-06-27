// 检查服务器上的错误日志
const { NodeSSH } = require('node-ssh');
const ssh = new NodeSSH();

async function check() {
  await ssh.connect({
    host: 'www.zhp98.fun',
    port: 22,
    username: 'root',
    password: 'Zhp199802!',
  });

  // 查看详细错误
  var log = await ssh.execCommand('pm2 logs familymap --lines 30 --nostream 2>&1');
  console.log('PM2 LOGS:');
  console.log(log.stdout);

  // 也检查 node 直接运行
  var test = await ssh.execCommand('cd "/vol1/1000/9自己的软件项目/家庭位置共享" && PORT=8090 node server.js 2>&1 &  sleep 3 && curl -s http://localhost:8090 | head -5');
  console.log('\nDIRECT TEST:');
  console.log(test.stdout);
  console.log(test.stderr);

  // 检查端口
  var port = await ssh.execCommand('ss -tlnp | grep 8090');
  console.log('\nPORT CHECK:');
  console.log(port.stdout);

  ssh.dispose();
}

check().catch(function(e) { console.error(e.message); ssh.dispose(); });
