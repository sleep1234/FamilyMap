module.exports = {
  apps: [{
    name: 'familymap',
    script: 'server.js',
    cwd: '/vol1/1000/9自己的软件项目/家庭位置共享',
    env: {
      PORT: 8090,
      AMAP_KEY: 'a80218fd754f53e944a193daa922e438',
      AMAP_JS_KEY: 'a80218fd754f53e944a193daa922e438',
      SSL_CERT_PATH: '/usr/trim/var/trim_connect/ssls/www.zhp98.fun/1782491513/fullchain.crt',
      SSL_KEY_PATH: '/usr/trim/var/trim_connect/ssls/www.zhp98.fun/1782491513/www.zhp98.fun.key',
      PWD_SALT: 'fm_2026_salt_xK9mP2vQ8n'
    }
  }]
};
