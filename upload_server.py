"""
FamilyMap 文件管理服务
- 上传截图/日志
- 下载编译好的 APK
- 浏览构建产物
"""
from http.server import HTTPServer, BaseHTTPRequestHandler
from socketserver import ThreadingMixIn
import os, urllib.parse, datetime, mimetypes, time as _time

UPLOAD_DIR = r'C:\FamilyMap\uploads'
BUILD_DIR = r'C:\FamilyMap\build\app\outputs\flutter-apk'
TEXT_DIR = r'C:\FamilyMap\uploads\texts'
PORT = 2121

def get_local_ip():
    import socket
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(('8.8.8.8', 80))
        return s.getsockname()[0]
    except:
        return '127.0.0.1'
    finally:
        s.close()

def file_info(path):
    try:
        st = os.stat(path)
        size = st.st_size
        size_str = f'{size/1024:.0f}KB' if size < 1024*1024 else f'{size/1024/1024:.1f}MB'
        mtime = datetime.datetime.fromtimestamp(st.st_mtime).strftime('%m-%d %H:%M')
        return size, size_str, mtime
    except:
        return 0, '-', '-'

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path

        # 首页
        if path == '/':
            self._serve_index()
        # 下载构建产物
        elif path.startswith('/dl/build/'):
            filename = path[len('/dl/build/'):]
            filepath = os.path.join(BUILD_DIR, filename)
            if os.path.isfile(filepath):
                self._serve_file(filepath, filename)
            else:
                self.send_error(404, '文件不存在')
        # 下载已上传文件
        elif path.startswith('/dl/upload/'):
            filename = path[len('/dl/upload/'):]
            filepath = os.path.join(UPLOAD_DIR, filename)
            if os.path.isfile(filepath):
                self._serve_file(filepath, filename)
            else:
                self.send_error(404, '文件不存在')
        # 获取最新文本列表（AJAX）
        elif path == '/api/texts':
            self._serve_texts()
        else:
            self.send_error(404)

    def _serve_index(self):
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.end_headers()

        # --- 构建产物 ---
        build_files = []
        if os.path.isdir(BUILD_DIR):
            for f in os.listdir(BUILD_DIR):
                fp = os.path.join(BUILD_DIR, f)
                if os.path.isfile(fp):
                    size, size_str, mtime = file_info(fp)
                    ext = os.path.splitext(f)[1].lower()
                    icon = '📦' if ext == '.apk' else '📄'
                    build_files.append((f, size_str, mtime, icon))
        build_files.sort(key=lambda x: x[2], reverse=True)

        build_html = ''
        for f, size_str, mtime, icon in build_files:
            dl_url = f'/dl/build/{urllib.parse.quote(f)}'
            is_apk = f.lower().endswith('.apk')
            if is_apk:
                build_html += f'''<li class="apk-item">
                    <span class="file-icon">{icon}</span>
                    <div class="file-info">
                      <a href="{dl_url}" class="apk-link">{f}</a>
                      <span class="file-meta">{size_str} · {mtime}</span>
                    </div>
                  </li>'''
            else:
                build_html += f'''<li>
                    <span class="file-icon">{icon}</span>
                    <a href="{dl_url}">{f}</a>
                    <span class="file-meta">{size_str} · {mtime}</span>
                  </li>'''
        if not build_html:
            build_html = '<li style="color:#64748b;text-align:center;padding:12px">暂无构建产物</li>'

        # --- 已上传文件 ---
        upload_files = []
        if os.path.isdir(UPLOAD_DIR):
            for f in os.listdir(UPLOAD_DIR):
                fp = os.path.join(UPLOAD_DIR, f)
                if os.path.isfile(fp):
                    size, size_str, mtime = file_info(fp)
                    ext = os.path.splitext(f)[1].lower()
                    if ext in ('.jpg','.jpeg','.png','.gif','.webp'):
                        icon = '🖼️'
                    elif ext in ('.txt','.log','.md'):
                        icon = '📝'
                    else:
                        icon = '📎'
                    upload_files.append((f, size_str, mtime, icon))
        upload_files.sort(key=lambda x: x[2], reverse=True)

        upload_html = ''
        for f, size_str, mtime, icon in upload_files:
            dl_url = f'/dl/upload/{urllib.parse.quote(f)}'
            upload_html += f'''<li>
                <span class="file-icon">{icon}</span>
                <a href="{dl_url}" target="_blank">{f}</a>
                <span class="file-meta">{size_str} · {mtime}</span>
              </li>'''
        if not upload_html:
            upload_html = '<li style="color:#64748b;text-align:center;padding:12px">暂无上传文件</li>'

        apk_count = sum(1 for f,_,_,_ in build_files if f.lower().endswith('.apk'))

        html = f'''<!DOCTYPE html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>FamilyMap</title>
<style>
*{{box-sizing:border-box;margin:0;padding:0}}
body{{font-family:system-ui,-apple-system,sans-serif;max-width:500px;margin:0 auto;padding:12px 16px 40px;background:#0f172a;color:#e2e8f0;min-height:100vh}}
h1{{text-align:center;font-size:22px;color:#818cf8;margin:8px 0 4px}}
.subtitle{{text-align:center;font-size:12px;color:#64748b;margin-bottom:12px}}

/* APK大按钮 */
.apk-btn{{display:block;background:linear-gradient(135deg,#4f46e5,#7c3aed);color:#fff;border:none;
  border-radius:14px;padding:16px;margin:12px 0;text-align:center;text-decoration:none;
  font-size:16px;font-weight:700;cursor:pointer;transition:transform .1s}}
.apk-btn:active{{transform:scale(0.97)}}
.apk-btn .apk-size{{font-size:13px;font-weight:400;opacity:.8;margin-top:2px}}
.apk-btn.disabled{{background:#334155;pointer-events:none;opacity:.5}}

/* 上传区 */
.upload-area{{border:2px dashed #4f46e5;border-radius:12px;padding:24px 16px;text-align:center;
  margin:12px 0;cursor:pointer;transition:background .15s}}
.upload-area:hover,.upload-area.drag{{background:#1e293b}}
.upload-area p{{margin:4px 0}}
input[type=file]{{display:none}}
.btn{{background:#4f46e5;color:#fff;border:none;border-radius:8px;padding:10px 20px;font-size:14px;
  cursor:pointer;width:100%;font-weight:600}}
.btn:hover{{background:#6366f1}}
#status{{text-align:center;margin:6px 0;color:#94a3b8;min-height:18px;font-size:13px}}

/* 文件列表 */
.section{{margin-top:16px}}
.section-title{{font-size:14px;color:#94a3b8;font-weight:600;margin-bottom:6px;display:flex;align-items:center;gap:6px}}
.section-title .badge{{background:#4f46e5;color:#fff;font-size:11px;padding:1px 7px;border-radius:8px}}
ul{{list-style:none;padding:0}}
li{{padding:8px 0;border-bottom:1px solid #1e293b;font-size:13px;display:flex;align-items:center;gap:8px;flex-wrap:wrap}}
li a{{color:#818cf8;text-decoration:none;word-break:break-all}}
li a:hover{{text-decoration:underline}}
.file-icon{{font-size:15px;flex-shrink:0}}
.file-meta{{color:#64748b;font-size:11px;margin-left:auto;flex-shrink:0}}
.apk-item{{padding:10px 0}}
.apk-link{{font-size:14px;font-weight:600;color:#a78bfa}}
.file-info{{display:flex;flex-direction:column;gap:1px}}

/* 刷新按钮 */
.refresh{{position:fixed;bottom:16px;right:16px;width:44px;height:44px;border-radius:50%;
  background:#4f46e5;color:#fff;border:none;font-size:20px;cursor:pointer;
  box-shadow:0 2px 12px rgba(79,70,229,.4);display:flex;align-items:center;justify-content:center}}
</style></head><body>
<h1>FamilyMap</h1>
<div class="subtitle">文件管理 · APK下载 · 截图上传 · 文本传输</div>

<!-- APK下载大按钮 -->
<a href="/dl/build/app-debug.apk" class="apk-btn {'disabled' if apk_count == 0 else ''}" id="apkBtn">
  {'📥 下载最新 APK' if apk_count > 0 else '⏳ 暂无APK构建'}
  <div class="apk-size" id="apkMeta"></div>
</a>

<!-- 上传区 -->
<div class="upload-area" id="dropZone" onclick="document.getElementById('fileInput').click()">
  <p>📤 点击选择或拖拽文件</p>
  <p style="font-size:11px;color:#64748b">截图、日志等任意文件</p>
</div>
<input type="file" id="fileInput" multiple onchange="uploadFiles(this.files)">
<button class="btn" onclick="document.getElementById('fileInput').click()">选择文件上传</button>
<div id="status"></div>

<!-- 文本传输区 -->
<div class="section">
  <div class="section-title">📋 文本传输 <span class="badge" id="textCount">0</span></div>
  <textarea id="textInput" placeholder="输入文本，跨设备复制粘贴..." rows="3"
    style="width:100%;background:#1e293b;color:#e2e8f0;border:1px solid #334155;border-radius:8px;
    padding:10px;font-size:14px;resize:vertical;font-family:inherit"></textarea>
  <button class="btn" style="margin-top:6px" onclick="sendText()">发送文本</button>
  <div id="textStatus" style="text-align:center;margin:4px 0;color:#94a3b8;min-height:16px;font-size:12px"></div>
  <ul id="textList"></ul>
</div>

<!-- 构建产物 -->
<div class="section">
  <div class="section-title">🔧 构建产物 <span class="badge">{len(build_files)}</span></div>
  <ul>{build_html}</ul>
</div>

<!-- 已上传文件 -->
<div class="section">
  <div class="section-title">📁 已上传文件 <span class="badge">{len(upload_files)}</span></div>
  <ul>{upload_html}</ul>
</div>

<button class="refresh" onclick="location.reload()" title="刷新">↻</button>

<script>
var dz=document.getElementById('dropZone');
dz.ondragover=function(e){{e.preventDefault();dz.classList.add('drag')}};
dz.ondragleave=function(){{dz.classList.remove('drag')}};
dz.ondrop=function(e){{e.preventDefault();dz.classList.remove('drag');uploadFiles(e.dataTransfer.files)}};

// APK按钮长按右键下载
var apkBtn=document.getElementById('apkBtn');
if(apkBtn&&!apkBtn.classList.contains('disabled')){{
  // 更新APK元信息
  var meta=document.querySelector('.apk-item .file-meta');
  if(meta)document.getElementById('apkMeta').textContent=meta.textContent;
}}

function uploadFiles(files){{
  var status=document.getElementById('status');
  var total=files.length,done=0,failed=0;
  for(var i=0;i<files.length;i++){{
    (function(file){{
      var fd=new FormData();
      fd.append('file',file);
      status.textContent='上传中: '+file.name+'...';
      var xhr=new XMLHttpRequest();
      xhr.open('POST','/upload');
      xhr.onload=function(){{
        done++;
        if(xhr.status!==200)failed++;
        status.textContent=failed?'完成 '+done+'/'+total+' ('+failed+'失败)':'上传完成 '+done+'/'+total;
        if(done===total)setTimeout(function(){{status.textContent=''}},3000);
      }};
      xhr.onerror=function(){{
        done++;failed++;
        status.textContent='上传失败: '+file.name;
        if(done===total)setTimeout(function(){{status.textContent=''}},3000);
      }};
      xhr.send(fd);
    }})(files[i]);
  }}
}}

// 文本传输
function sendText(){{
  var text=document.getElementById('textInput').value.trim();
  if(!text)return;
  var status=document.getElementById('textStatus');
  status.textContent='发送中...';
  var xhr=new XMLHttpRequest();
  xhr.open('POST','/text');
  xhr.setRequestHeader('Content-Type','application/x-www-form-urlencoded');
  xhr.onload=function(){{
    if(xhr.status===200){{
      document.getElementById('textInput').value='';
      status.textContent='已发送';
      loadTexts();
    }}else{{status.textContent='发送失败';}}
    setTimeout(function(){{status.textContent=''}},2000);
  }};
  xhr.onerror=function(){{status.textContent='发送失败';}};
  xhr.send('text='+encodeURIComponent(text));
}}

function loadTexts(){{
  var xhr=new XMLHttpRequest();
  xhr.open('GET','/api/texts');
  xhr.onload=function(){{
    if(xhr.status!==200)return;
    var texts=JSON.parse(xhr.responseText);
    document.getElementById('textCount').textContent=texts.length;
    var list=document.getElementById('textList');
    list.innerHTML='';
    texts.forEach(function(t){{
      var li=document.createElement('li');
      li.style.cssText='flex-direction:column;align-items:flex-start;gap:4px';
      var content=document.createElement('div');
      content.style.cssText='word-break:break-all;white-space:pre-wrap;font-size:13px;color:#e2e8f0;width:100%';
      content.textContent=t.content;
      var meta=document.createElement('div');
      meta.style.cssText='display:flex;align-items:center;gap:8px;width:100%';
      var time=document.createElement('span');
      time.style.cssText='color:#64748b;font-size:11px';
      time.textContent=t.time;
      var copyBtn=document.createElement('button');
      copyBtn.textContent='复制';
      copyBtn.style.cssText='background:#334155;color:#94a3b8;border:none;border-radius:4px;padding:2px 8px;font-size:11px;cursor:pointer;margin-left:auto';
      copyBtn.onclick=function(){{
        // 兼容 HTTP 的复制方式（navigator.clipboard 需要 HTTPS）
        var ta=document.createElement('textarea');
        ta.value=t.content;
        ta.style.cssText='position:fixed;left:-9999px';
        document.body.appendChild(ta);
        ta.select();
        try{{document.execCommand('copy');copyBtn.textContent='已复制';}}catch(e){{copyBtn.textContent='失败';}}
        document.body.removeChild(ta);
        setTimeout(function(){{copyBtn.textContent='复制'}},1500);
      }};
      meta.appendChild(time);
      meta.appendChild(copyBtn);
      li.appendChild(content);
      li.appendChild(meta);
      list.appendChild(li);
    }});
  }};
  xhr.send();
}}
loadTexts();
</script></body></html>'''
        self.wfile.write(html.encode('utf-8'))

    def _serve_file(self, filepath, filename):
        """支持 Range 请求的文件下载（断点续传）"""
        try:
            file_size = os.path.getsize(filepath)
            mime = mimetypes.guess_type(filename)[0] or 'application/octet-stream'

            # 解析 Range 头：bytes=start-end
            range_header = self.headers.get('Range')
            if range_header and range_header.startswith('bytes='):
                # 只处理单段 Range（最常见的情况）
                ranges = range_header[6:].split('-')
                start = int(ranges[0]) if ranges[0] else 0
                end = int(ranges[1]) if ranges[1] else file_size - 1
                # 边界检查
                start = max(0, min(start, file_size - 1))
                end = max(start, min(end, file_size - 1))
                content_length = end - start + 1

                self.send_response(206)  # Partial Content
                self.send_header('Content-Type', mime)
                self.send_header('Content-Length', str(content_length))
                self.send_header('Content-Range', f'bytes {start}-{end}/{file_size}')
                self.send_header('Content-Disposition', f'attachment; filename="{filename}"')
                self.send_header('Accept-Ranges', 'bytes')
                self.end_headers()
                with open(filepath, 'rb') as f:
                    f.seek(start)
                    remaining = content_length
                    while remaining > 0:
                        chunk = f.read(min(65536, remaining))
                        if not chunk:
                            break
                        self.wfile.write(chunk)
                        remaining -= len(chunk)
                print(f'[下载] {filename} ({start}-{end}/{file_size}) 断点续传')
            else:
                # 无 Range 头，正常完整下载
                self.send_response(200)
                self.send_header('Content-Type', mime)
                self.send_header('Content-Length', str(file_size))
                self.send_header('Content-Disposition', f'attachment; filename="{filename}"')
                self.send_header('Accept-Ranges', 'bytes')  # 告知客户端支持断点续传
                self.end_headers()
                with open(filepath, 'rb') as f:
                    while True:
                        chunk = f.read(65536)
                        if not chunk:
                            break
                        self.wfile.write(chunk)
                print(f'[下载] {filename} ({file_size} bytes)')
        except Exception as e:
            self.send_error(500, str(e))

    def do_POST(self):
        if self.path == '/upload':
            content_type = self.headers.get('Content-Type', '')
            if 'multipart/form-data' not in content_type:
                self.send_error(400, 'Not multipart')
                return

            boundary = content_type.split('boundary=')[1].encode()
            content_length = int(self.headers.get('Content-Length', 0))
            body = self.rfile.read(content_length)

            parts = body.split(b'--' + boundary)
            uploaded = []
            for part in parts:
                if b'filename="' not in part:
                    continue
                header_end = part.find(b'\r\n\r\n')
                if header_end < 0:
                    continue
                header = part[:header_end].decode('utf-8', errors='replace')
                filename_start = header.find('filename="') + 10
                filename_end = header.find('"', filename_start)
                filename = header[filename_start:filename_end]
                if not filename:
                    continue

                filename = os.path.basename(filename)
                timestamp = datetime.datetime.now().strftime('%H%M%S_')
                filename = timestamp + filename

                file_data = part[header_end+4:]
                if file_data.endswith(b'\r\n'):
                    file_data = file_data[:-2]

                filepath = os.path.join(UPLOAD_DIR, filename)
                with open(filepath, 'wb') as f:
                    f.write(file_data)
                uploaded.append(f'{filename} ({len(file_data)} bytes)')
                print(f'[上传] {filename} ({len(file_data)} bytes)')

            self.send_response(200)
            self.send_header('Content-Type', 'text/plain')
            self.end_headers()
            self.wfile.write(b'OK')

        elif self.path == '/text':
            # 接收文本片段，保存到文件
            content_length = int(self.headers.get('Content-Length', 0))
            body = self.rfile.read(content_length).decode('utf-8', errors='replace')
            # URL decode
            import urllib.parse
            text = urllib.parse.unquote_plus(body).lstrip('text=')
            if not text.strip():
                self.send_error(400, '空文本')
                return

            os.makedirs(TEXT_DIR, exist_ok=True)
            timestamp = datetime.datetime.now().strftime('%H%M%S')
            filepath = os.path.join(TEXT_DIR, f'{timestamp}.txt')
            with open(filepath, 'w', encoding='utf-8') as f:
                f.write(text)
            print(f'[文本] 收到 {len(text)} 字符')

            self.send_response(200)
            self.send_header('Content-Type', 'text/plain')
            self.end_headers()
            self.wfile.write(b'OK')

        else:
            self.send_error(404)

    def _serve_texts(self):
        """返回最新文本列表（JSON）"""
        import json
        texts = []
        if os.path.isdir(TEXT_DIR):
            for f in sorted(os.listdir(TEXT_DIR), reverse=True)[:20]:
                fp = os.path.join(TEXT_DIR, f)
                if os.path.isfile(fp):
                    try:
                        content = open(fp, 'r', encoding='utf-8').read()
                        mtime = datetime.datetime.fromtimestamp(os.path.getmtime(fp)).strftime('%H:%M:%S')
                        texts.append({'time': mtime, 'content': content})
                    except:
                        pass
        self.send_response(200)
        self.send_header('Content-Type', 'application/json; charset=utf-8')
        self.send_header('Access-Control-Allow-Origin', '*')
        self.end_headers()
        self.wfile.write(json.dumps(texts, ensure_ascii=False).encode('utf-8'))

    def log_message(self, format, *args):
        pass  # 静默日志

class ThreadedHTTPServer(ThreadingMixIn, HTTPServer):
    """多线程 HTTP 服务器，每个请求独立线程处理，支持并发下载"""
    daemon_threads = True

if __name__ == '__main__':
    os.makedirs(UPLOAD_DIR, exist_ok=True)
    local_ip = get_local_ip()
    server = ThreadedHTTPServer(('0.0.0.0', PORT), Handler)
    print(f'''
  ╔══════════════════════════════════════╗
  ║   FamilyMap 文件管理服务已启动       ║
  ╠══════════════════════════════════════╣
  ║  局域网: http://{local_ip}:{PORT}     ║
  ║  本机:   http://127.0.0.1:{PORT}      ║
  ║  上传目录: {UPLOAD_DIR}
  ║  构建目录: {BUILD_DIR}
  ║  多线程 + 断点续传已启用             ║
  ║  手机和电脑需在同一WiFi下           ║
  ╚══════════════════════════════════════╝
''')
    server.serve_forever()
