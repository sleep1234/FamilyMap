const { NodeSSH } = require('node-ssh');
const ssh = new NodeSSH();
var remotePath = '/vol1/1000/9自己的软件项目/家庭位置共享';

async function run() {
  await ssh.connect({ host: 'www.zhp98.fun', port: 22, username: 'root', password: 'Zhp199802!' });
  
  // 删除旧数据库
  await ssh.execCommand('rm -f "' + remotePath + '/familymap.db" 2>/dev/null');
  console.log('old db removed');
  
  // 上传修复后的 server.js
  await ssh.putFile('C:/FamilyMap/server.js', remotePath + '/server.js');
  console.log('server.js uploaded');
  
  // 重启 pm2
  await ssh.execCommand('pm2 restart familymap');
  console.log('pm2 restarted');
  
  await new Promise(function(r) { setTimeout(r, 4000); });
  
  var port = await ssh.execCommand('ss -tlnp | grep 8090');
  console.log('port: ' + port.stdout.trim());
  
  var log = await ssh.execCommand('pm2 logs familymap --lines 8 --nostream 2>&1');
  console.log('log:\n' + log.stdout.substring(0, 800));
  
  var curl = await ssh.execCommand('curl -s http://localhost:8090 | head -5');
  console.log('curl response: ' + curl.stdout);
  
  // 测试 API
  var apiTest = await ssh.execCommand('curl -s http://localhost:8090/api/users -X POST -H "Content-Type: application/json" -d \'{"name":"test"}\'');
  console.log('api test: ' + apiTest.stdout);
  
  ssh.dispose();
}
run().catch(function(e) { console.error(e.message); ssh.dispose(); });
