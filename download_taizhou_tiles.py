#!/usr/bin/env python3
"""台州市离线地图瓦片下载器

用法: python download_taizhou_tiles.py [--zoom 10-15] [--output ./tiles]

默认下载台州市区域 zoom 10-15 的高德地图瓦片到 ./tiles/ 目录
瓦片目录结构: tiles/{z}/{x}/{y}.png
"""

import os
import sys
import math
import time
import argparse
import urllib.request
import urllib.error
from concurrent.futures import ThreadPoolExecutor, as_completed

# 台州市边界 (WGS84)
TAIZHOU_BOUNDS = {
    'north': 29.0,
    'south': 27.8,
    'east': 122.0,
    'west': 120.0,
}

# 高德瓦片服务器
TILE_URLS = [
    'https://webrd01.is.autonavi.com/appmaptile?lang=zh_cn&size=1&scale=1&style=8&x={x}&y={y}&z={z}',
    'https://webrd02.is.autonavi.com/appmaptile?lang=zh_cn&size=1&scale=1&style=8&x={x}&y={y}&z={z}',
    'https://webrd03.is.autonavi.com/appmaptile?lang=zh_cn&size=1&scale=1&style=8&x={x}&y={y}&z={z}',
    'https://webrd04.is.autonavi.com/appmaptile?lang=zh_cn&size=1&scale=1&style=8&x={x}&y={y}&z={z}',
]

def lat_lng_to_tile(lat, lng, zoom):
    """经纬度转瓦片坐标"""
    n = 2 ** zoom
    x = int((lng + 180) / 360 * n)
    y = int((1 - math.log(math.tan(math.radians(lat)) + 1 / math.cos(math.radians(lat))) / math.pi) / 2 * n)
    return x, y

def get_tile_range(bounds, zoom):
    """获取指定缩放级别的瓦片范围"""
    x_min, y_max = lat_lng_to_tile(bounds['north'], bounds['west'], zoom)
    x_max, y_min = lat_lng_to_tile(bounds['south'], bounds['east'], zoom)
    tiles = []
    for x in range(x_min, x_max + 1):
        for y in range(y_min, y_max + 1):
            tiles.append((zoom, x, y))
    return tiles

def download_tile(z, x, y, output_dir, retries=3):
    """下载单个瓦片"""
    tile_path = os.path.join(output_dir, str(z), str(x), f'{y}.png')
    if os.path.exists(tile_path):
        return 'skip'

    os.makedirs(os.path.dirname(tile_path), exist_ok=True)
    
    for attempt in range(retries):
        url = TILE_URLS[(x + y) % len(TILE_URLS)].format(x=x, y=y, z=z)
        try:
            req = urllib.request.Request(url, headers={
                'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
                'Referer': 'https://www.amap.com/',
            })
            resp = urllib.request.urlopen(req, timeout=10)
            data = resp.read()
            if len(data) < 100:
                raise Exception(f'Tile too small: {len(data)} bytes')
            with open(tile_path, 'wb') as f:
                f.write(data)
            return 'ok'
        except Exception as e:
            if attempt < retries - 1:
                time.sleep(0.5 * (attempt + 1))
            else:
                return f'fail: {e}'
    return 'fail'

def main():
    parser = argparse.ArgumentParser(description='台州市离线地图瓦片下载器')
    parser.add_argument('--zoom', default='10-15', help='缩放级别范围 (默认: 10-15)')
    parser.add_argument('--output', default='./tiles_taizhou', help='输出目录')
    parser.add_argument('--workers', type=int, default=4, help='并发下载数 (默认: 4)')
    parser.add_argument('--delay', type=float, default=0.1, help='请求间隔秒数 (默认: 0.1)')
    args = parser.parse_args()

    zoom_parts = args.zoom.split('-')
    z_min, z_max = int(zoom_parts[0]), int(zoom_parts[-1])

    all_tiles = []
    for z in range(z_min, z_max + 1):
        tiles = get_tile_range(TAIZHOU_BOUNDS, z)
        all_tiles.extend(tiles)
        print(f'  Zoom {z}: {len(tiles)} tiles')

    print(f'\n总计 {len(all_tiles)} 个瓦片, 输出目录: {args.output}')
    print(f'并发: {args.workers}, 请求间隔: {args.delay}s\n')

    os.makedirs(args.output, exist_ok=True)

    ok = skip = fail = 0
    with ThreadPoolExecutor(max_workers=args.workers) as pool:
        futures = {}
        for z, x, y in all_tiles:
            f = pool.submit(download_tile, z, x, y, args.output)
            futures[f] = (z, x, y)

        for i, f in enumerate(as_completed(futures), 1):
            result = f.result()
            if result == 'ok':
                ok += 1
            elif result == 'skip':
                skip += 1
            else:
                fail += 1

            if i % 100 == 0 or i == len(all_tiles):
                print(f'  进度: {i}/{len(all_tiles)} (下载:{ok} 跳过:{skip} 失败:{fail})')

            time.sleep(args.delay)

    print(f'\n完成! 下载:{ok} 跳过:{skip} 失败:{fail}')
    print(f'瓦片目录: {os.path.abspath(args.output)}')

if __name__ == '__main__':
    main()
