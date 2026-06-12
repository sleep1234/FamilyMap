#!/usr/bin/env node
// ==================== 密码迁移工具 ====================
// 用于批量将旧 SHA-256 密码迁移到 bcrypt
// 运行方式: node migrate-passwords.js

const crypto = require('crypto');
const bcrypt = require('bcrypt');
const initSqlJs = require('sql.js');
const fs = require('fs');
const path = require('path');

const DB_PATH = process.env.DB_PATH || path.join(__dirname, 'familymap.db');
const OLD_SALT = 'FamilyMap2026Salt';
const BCRYPT_ROUNDS = 12;

async function migrate() {
  if (!fs.existsSync(DB_PATH)) {
    console.log('数据库文件不存在，无需迁移');
    return;
  }

  const SQL = await initSqlJs();
  const buf = fs.readFileSync(DB_PATH);
  const db = new SQL.Database(buf);

  // 查找所有使用旧格式密码的用户（password_hash 不以 $2b$ 开头）
  const stmt = db.prepare("SELECT id, username, password_hash FROM users WHERE password_hash IS NOT NULL AND password_hash NOT LIKE '$2b$%'");
  const users = [];
  while (stmt.step()) {
    users.push(stmt.getAsObject());
  }
  stmt.free();

  if (users.length === 0) {
    console.log('没有需要迁移的用户（所有密码已是 bcrypt 格式）');
    return;
  }

  console.log(`找到 ${users.length} 个使用旧密码格式的用户:`);
  users.forEach(u => console.log(`  - ${u.username || u.id}`));
  console.log('');
  console.log('⚠️  此工具无法自动迁移密码（需要原始密码）');
  console.log('建议方案:');
  console.log('  1. 在登录接口中实现自动迁移（见 FIXES.md 方案 A）');
  console.log('  2. 要求用户重新设置密码');
  console.log('  3. 删除数据库重新开始');
  console.log('');

  // 可选：将旧密码标记为需要重置
  // db.run("UPDATE users SET password_hash = 'NEEDS_RESET' WHERE password_hash IS NOT NULL AND password_hash NOT LIKE '$2b$%'");
  // fs.writeFileSync(DB_PATH, Buffer.from(db.export()));
  // console.log('已将旧密码标记为 NEEDS_RESET，用户下次登录时需要重置密码');
}

migrate().catch(err => {
  console.error('迁移失败:', err);
  process.exit(1);
});
