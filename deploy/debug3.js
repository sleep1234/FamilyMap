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

  // Check sql.js version
  let r = await ssh.execCommand(`cat ${remotePath}/node_modules/sql.js/package.json | grep version | head -1`);
  console.log('sql.js version:', r.stdout);

  // Test the exact CREATE TABLE statement on the server
  r = await ssh.execCommand(`cd ${remotePath} && node -e "
const initSqlJs = require('sql.js');
async function test() {
  const SQL = await initSqlJs();
  const db = new SQL.Database();
  try {
    db.run(\`CREATE TABLE contacts (id INTEGER PRIMARY KEY AUTOINCREMENT, user_id TEXT NOT NULL, contact_id TEXT NOT NULL, type TEXT DEFAULT 'friend', created_at DATETIME DEFAULT CURRENT_TIMESTAMP)\`);
    console.log('SUCCESS');
  } catch(e) {
    console.log('ERROR:', e.message);
  }
}
test();
"`);
  console.log('Direct SQL test:', r.stdout || r.stderr);

  // Check if there's a cached WASM or something
  r = await ssh.execCommand(`find ${remotePath} -name "*.wasm" 2>/dev/null`);
  console.log('WASM files:', r.stdout || 'none');

  // Check node version
  r = await ssh.execCommand('node --version');
  console.log('Node version:', r.stdout);

  await ssh.dispose();
}

main().catch(console.error);
