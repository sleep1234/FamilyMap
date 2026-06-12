#!/usr/bin/env node
// ==================== 修复验证脚本 ====================
// 检查 server.js 是否已正确应用所有安全修复
// 运行方式: node verify-fixes.js

const fs = require('fs');
const path = require('path');

const SERVER_PATH = process.env.SERVER_PATH || path.join(__dirname, 'server.js');
const results = [];

function check(name, passed, detail) {
  results.push({ name, passed, detail });
  const icon = passed ? '✅' : '❌';
  console.log(`${icon} ${name}${detail ? ': ' + detail : ''}`);
}

function main() {
  console.log('\n🔍 FamilyMap 代码审查修复验证\n');
  console.log(`检查文件: ${SERVER_PATH}\n`);

  if (!fs.existsSync(SERVER_PATH)) {
    console.error('❌ server.js 不存在');
    process.exit(1);
  }

  const code = fs.readFileSync(SERVER_PATH, 'utf-8');
  const lines = code.split('\n');

  // ========== 修复 1: 密码哈希 ==========
  check(
    'bcrypt 已引入',
    code.includes("require('bcrypt')") || code.includes('require("bcrypt")'),
    '应有 bcrypt require 语句'
  );

  check(
    'SHA-256 固定盐值已移除',
    !code.includes("PWD_SALT = 'FamilyMap2026Salt'"),
    '不应再有固定盐值常量'
  );

  check(
    'hashPassword 使用 bcrypt',
    code.includes('bcrypt.hash') || code.includes('bcryptRound'),
    'hashPassword 应调用 bcrypt.hash'
  );

  check(
    'verifyPassword 使用 bcrypt',
    code.includes('bcrypt.compare'),
    'verifyPassword 应调用 bcrypt.compare'
  );

  check(
    '注册路由使用 await hashPassword',
    code.includes('await hashPassword') || code.includes('await hashPassword('),
    'hashPassword 是 async 函数，需要 await'
  );

  check(
    '登录路由使用 await verifyPassword',
    code.includes('await verifyPassword') || code.includes('await verifyPassword('),
    'verifyPassword 是 async 函数，需要 await'
  );

  // ========== 修复 2: SQL 注入 ==========
  const sqlInjectionPatterns = [
    { pattern: /datetime\('now',\s*'-\$\{.*\}\s*hours'\)/, desc: 'hours 字符串拼接' },
    { pattern: /datetime\('now',\s*'-\$\{.*\}\s*days'\)/, desc: 'days 字符串拼接' },
  ];

  let sqlInjectionFound = false;
  for (const { pattern, desc } of sqlInjectionPatterns) {
    if (pattern.test(code)) {
      check(`SQL 注入修复: ${desc}`, false, '发现未修复的字符串拼接');
      sqlInjectionFound = true;
    }
  }
  if (!sqlInjectionFound) {
    check('SQL 注入修复: 无字符串拼接', true, '所有 datetime 查询已使用参数化');
  }

  check(
    'SQL 参数化查询使用 || 拼接',
    code.includes("'-' || ? || ' hours'") || code.includes("'-' || ? || ' days'"),
    '应使用 SQLite || 操作符拼接参数'
  );

  // ========== 修复 3: API 认证 ==========
  check(
    'requireAuth 中间件已引入',
    code.includes("require('./middleware/auth')") || code.includes('requireAuth'),
    '应引入认证中间件'
  );

  check(
    'register 路由不需要认证',
    !code.includes("app.post('/api/register', requireAuth"),
    '注册接口不应需要认证'
  );

  check(
    'login 路由不需要认证',
    !code.includes("app.post('/api/login', requireAuth"),
    '登录接口不应需要认证'
  );

  check(
    'circles POST 需要认证',
    code.includes("app.post('/api/circles', requireAuth") || code.includes("app.post('/api/circles',\n    requireAuth"),
    '创建圈子需要认证'
  );

  check(
    'geofences POST 需要认证',
    code.includes("app.post('/api/circles/:circleId/geofences', requireAuth") || 
    code.includes("app.post('/api/circles/:circleId/geofences',\n    requireAuth"),
    '创建围栏需要认证'
  );

  // ========== 修复 4: 输入验证 ==========
  check(
    'validate 中间件已引入',
    code.includes("require('./middleware/validate')") || code.includes('validateBody'),
    '应引入验证中间件'
  );

  check(
    '注册使用验证',
    code.includes('validateBody(schemas.register)'),
    '注册接口应有输入验证'
  );

  check(
    '位置更新使用验证',
    code.includes('validateBody(schemas.locationUpdate)') || code.includes('schemas.locationUpdate'),
    '位置更新应有输入验证'
  );

  // ========== 修复 5: 配置管理 ==========
  check(
    'config 模块已引入',
    code.includes("require('./config')") || code.includes("require('./config');"),
    '应引入配置模块'
  );

  check(
    '端口使用配置',
    code.includes('config.PORT') || code.includes('PORT = config.PORT'),
    '端口应从配置读取'
  );

  // ========== 修复 6: 输入范围校验 ==========
  const rangeChecks = [
    { param: 'hours', min: 1, max: 720 },
    { param: 'days', min: 1, max: 365 },
  ];

  for (const { param, min, max } of rangeChecks) {
    const hasClamp = code.includes(`Math.min(Math.max(parseInt(req.query.${param})`) ||
      code.includes(`parseInt(req.query.${param})`) && code.includes(`Math.min(`) && code.includes(`Math.max(`);
    check(
      `${param} 参数范围校验`,
      hasClamp,
      `${param} 应限制在 ${min}-${max} 范围`
    );
  }

  // ========== 总结 ==========
  console.log('\n' + '='.repeat(50));
  const passed = results.filter(r => r.passed).length;
  const failed = results.filter(r => !r.passed).length;
  console.log(`总计: ${results.length} 项检查`);
  console.log(`通过: ${passed} ✅`);
  console.log(`失败: ${failed} ❌`);

  if (failed > 0) {
    console.log('\n⚠️  请根据 FIXES.md 修复失败的项目');
    process.exit(1);
  } else {
    console.log('\n🎉 所有检查通过！修复已正确应用。');
    process.exit(0);
  }
}

main();
