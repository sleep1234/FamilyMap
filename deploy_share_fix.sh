#!/bin/bash
# 分享链接修复部署脚本 - 在服务器上执行
# 用法: bash deploy_share_fix.sh

cd "$(dirname "$0")" || exit 1
echo "当前目录: $(pwd)"

# 备份
cp -f routes/share.js routes/share.js.bak 2>/dev/null
cp -f server.js server.js.bak 2>/dev/null

echo "文件已更新（share.js + server.js）"

# 重启服务（根据实际进程管理方式调整）
if command -v pm2 &> /dev/null; then
    pm2 restart familymap 2>/dev/null || pm2 restart all
    echo "已通过 pm2 重启服务"
elif [ -f ecosystem.config.js ]; then
    pm2 restart ecosystem.config.js
    echo "已通过 pm2 ecosystem 重启服务"
else
    # 尝试找到 node server.js 进程并重启
    PID=$(pgrep -f "node.*server.js" | head -1)
    if [ -n "$PID" ]; then
        kill $PID
        sleep 1
        nohup node server.js > /dev/null 2>&1 &
        echo "已重启 server.js (PID: $!)"
    else
        echo "未找到运行中的服务，请手动重启: node server.js"
    fi
fi

echo "部署完成！"
