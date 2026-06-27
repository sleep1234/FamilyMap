#!/bin/bash
# FamilyMap 后端启动脚本
cd "$(dirname "$0")"

# 安装依赖（首次）
if [ ! -d "node_modules" ]; then
    echo "Installing dependencies..."
    npm install --production
fi

# 启动服务
PORT=8090 node server.js
