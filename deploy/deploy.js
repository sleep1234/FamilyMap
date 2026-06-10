// SSH deploy - compatible with Node 18+
const { NodeSSH } = require('node-ssh');
const path = require('path');
const fs = require('fs');

const ssh = new NodeSSH();

const CONFIG = {
  host: 'www.zhp0104.fun',
  port: 22,
  username: 'root',
  password: 'Zhp199802!',
  remotePath: '/vol1/1000/9自己的软件项目/家庭位置共享',
  appPort: 8090,
};

async function deploy() {
  console.log('1. connecting...');
  await ssh.connect({
    host: CONFIG.host,
    port: CONFIG.port,
    username: CONFIG.username,
    password: CONFIG.password,
  });
  console.log('   connected!');

  // mkdir
  console.log('2. creating directory...');
  await ssh.execCommand('mkdir -p "' + CONFIG.remotePath + '"');
  console.log('   done');

  // check node
  console.log('3. checking node...');
  var nodeVer = await ssh.execCommand('node --version 2>/dev/null || echo "none"');
  console.log('   Node: ' + nodeVer.stdout.trim());

  if (nodeVer.stdout.trim() === 'none') {
    console.log('   installing node...');
    await ssh.execCommand('curl -fsSL https://deb.nodesource.com/setup_20.x | bash - && apt-get install -y nodejs', { execOptions: { timeout: 120000 } });
  }

  // upload server.js
  console.log('4. uploading files...');
  var localDir = path.join(__dirname);
  await ssh.putFile(path.join(localDir, 'server.js'), CONFIG.remotePath + '/server.js');
  console.log('   server.js uploaded');

  // upload package.json as a temp file then write it
  var pkgJson = {
    name: 'familymap-server',
    version: '0.1.0',
    main: 'server.js',
    scripts: { start: 'node server.js' },
    dependencies: {
      express: '^4.21.0',
      'socket.io': '^4.8.0',
      'sql.js': '^1.11.0',
    },
  };
  var pkgPath = path.join(localDir, '_pkg.json');
  fs.writeFileSync(pkgPath, JSON.stringify(pkgJson, null, 2));
  await ssh.putFile(pkgPath, CONFIG.remotePath + '/package.json');
  fs.unlinkSync(pkgPath);
  console.log('   package.json uploaded');

  // upload start.sh
  await ssh.putFile(path.join(localDir, 'start.sh'), CONFIG.remotePath + '/start.sh');
  await ssh.execCommand('chmod +x "' + CONFIG.remotePath + '/start.sh"');
  console.log('   start.sh uploaded');

  // upload public
  var publicDir = path.join(localDir, 'public');
  if (fs.existsSync(publicDir)) {
    console.log('   uploading public directory...');
    await ssh.putDirectory(publicDir, CONFIG.remotePath + '/public', {
      recursive: true,
      validate: function(p) { return p.indexOf('node_modules') < 0; },
    });
    console.log('   public uploaded');
  }

  // install deps
  console.log('5. installing npm deps...');
  var installResult = await ssh.execCommand('cd "' + CONFIG.remotePath + '" && npm install --production 2>&1', { execOptions: { timeout: 120000 } });
  console.log('   deps installed');

  // stop old process
  console.log('6. stopping old process...');
  await ssh.execCommand('pkill -f "node ' + CONFIG.remotePath + '/server.js" 2>/dev/null || true');
  await ssh.execCommand('fuser -k ' + CONFIG.appPort + '/tcp 2>/dev/null || true');
  await new Promise(function(resolve) { setTimeout(resolve, 2000); });

  // check if pm2 exists
  var pm2Check = await ssh.execCommand('which pm2 2>/dev/null || echo "no"');
  var hasPm2 = pm2Check.stdout.trim() !== 'no';

  // start service
  console.log('7. starting service on port ' + CONFIG.appPort + '...');
  
  if (hasPm2) {
    // delete old pm2 entry if exists
    await ssh.execCommand('pm2 delete familymap 2>/dev/null || true');
    await ssh.execCommand('cd "' + CONFIG.remotePath + '" && PORT=' + CONFIG.appPort + ' pm2 start server.js --name familymap');
    await ssh.execCommand('pm2 save');
    console.log('   started via pm2');
  } else {
    await ssh.execCommand('cd "' + CONFIG.remotePath + '" && PORT=' + CONFIG.appPort + ' nohup node server.js > "' + CONFIG.remotePath + '/server.log" 2>&1 &');
    console.log('   started via nohup');
    // try installing pm2 for auto-restart
    console.log('   installing pm2 for process management...');
    await ssh.execCommand('npm install -g pm2 2>&1', { execOptions: { timeout: 60000 } });
    await ssh.execCommand('pkill -f "node ' + CONFIG.remotePath + '/server.js" 2>/dev/null || true');
    await new Promise(function(resolve) { setTimeout(resolve, 2000); });
    await ssh.execCommand('cd "' + CONFIG.remotePath + '" && PORT=' + CONFIG.appPort + ' pm2 start server.js --name familymap');
    await ssh.execCommand('pm2 save && pm2 startup');
    console.log('   pm2 installed and configured');
  }

  // wait and check
  await new Promise(function(resolve) { setTimeout(resolve, 3000); });

  var portCheck = await ssh.execCommand('ss -tlnp | grep ' + CONFIG.appPort + ' || echo "not_listening"');
  if (portCheck.stdout.indexOf(String(CONFIG.appPort)) >= 0) {
    console.log('   port ' + CONFIG.appPort + ' is listening');
  } else {
    console.log('   checking logs...');
    var logResult = await ssh.execCommand('tail -10 "' + CONFIG.remotePath + '/server.log" 2>/dev/null || pm2 logs familymap --lines 10 --nostream 2>/dev/null');
    console.log('   log: ' + logResult.stdout.trim().substring(0, 300));
  }

  // firewall
  console.log('8. checking firewall...');
  await ssh.execCommand('ufw allow ' + CONFIG.appPort + '/tcp 2>/dev/null || iptables -I INPUT -p tcp --dport ' + CONFIG.appPort + ' -j ACCEPT 2>/dev/null || true');

  // final check
  var curlResult = await ssh.execCommand('curl -s http://localhost:' + CONFIG.appPort + ' 2>&1 | head -3 || echo "curl_failed"');
  console.log('   curl test: ' + curlResult.stdout.trim().substring(0, 100));

  console.log('\n========================================');
  console.log('  DEPLOY DONE!');
  console.log('  API: http://' + CONFIG.host + ':' + CONFIG.appPort);
  console.log('  WS:  ws://' + CONFIG.host + ':' + CONFIG.appPort);
  console.log('========================================\n');

  ssh.dispose();
}

deploy().catch(function(err) {
  console.error('DEPLOY FAILED:', err.message);
  ssh.dispose();
  process.exit(1);
});
