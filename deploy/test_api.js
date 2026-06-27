const { NodeSSH } = require('node-ssh');
const ssh = new NodeSSH();

async function main() {
  await ssh.connect({
    host: 'www.zhp98.fun',
    port: 22,
    username: 'root',
    password: 'Zhp199802!'
  });

  // Test key API endpoints
  const tests = [
    ['POST /api/users', `curl -s -X POST http://localhost:8090/api/users -H "Content-Type: application/json" -d '{"name":"Alice"}'`],
    ['POST /api/circles', `curl -s -X POST http://localhost:8090/api/circles -H "Content-Type: application/json" -d '{"name":"家庭圈","userId":"u_test1"}'`],
    ['POST /api/users/u_test1/locations', `curl -s -X POST http://localhost:8090/api/users/u_test1/locations -H "Content-Type: application/json" -d '{"latitude":39.9042,"longitude":116.4074,"accuracy":10,"batteryLevel":80,"speed":0}'`],
    ['GET /api/users/u_test1', `curl -s http://localhost:8090/api/users/u_test1`],
  ];

  for (const [name, cmd] of tests) {
    const r = await ssh.execCommand(cmd);
    console.log(`${name}: ${r.stdout?.substring(0, 200) || r.stderr}`);
  }

  // Test external access
  const extResult = await ssh.execCommand('curl -s -X POST http://www.zhp98.fun:8090/api/users -H "Content-Type: application/json" -d \'{"name":"ExternalTest"}\'');
  console.log(`External POST /api/users: ${extResult.stdout?.substring(0, 200) || extResult.stderr}`);

  await ssh.dispose();
}

main().catch(console.error);
