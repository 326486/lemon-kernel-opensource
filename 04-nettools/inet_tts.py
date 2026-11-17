# Edge-TTS 纯标准库实现（WebSocket over ssl，无需aiohttp；微软在线神经声音，免key）
import argparse, sys, os, socket, ssl, base64, hashlib, struct, uuid, json, datetime
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from netcommon import out, die, clean

HOST = 'speech.platform.bing.com'
PATH = '/consumer/speech/synthesize/read/edge/v1?trustedclienttoken=6A5AA1D4EAFF4E9FB37E23D68491D6F4'
TOKEN = '6A5AA1D4EAFF4E9FB37E23D68491D6F4'

def _ts():
    return datetime.datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%S.%f')[:-3] + 'Z'

def _ws_connect():
    raw = socket.create_connection((HOST, 443), timeout=30)
    ctx = ssl.create_default_context()
    s = ctx.wrap_socket(raw, server_hostname=HOST)
    key = base64.b64encode(os.urandom(16)).decode()
    req = ('GET %s HTTP/1.1\r\nHost: %s\r\nConnection: Upgrade\r\nPragma: no-cache\r\n'
           'Cache-Control: no-cache\r\n'
           'User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36 Edg/130.0.0.0\r\n'
           'Upgrade: websocket\r\nOrigin: chrome-extension://jdiccldimpdaibmpdkjnbmckianbfold\r\n'
           'Sec-WebSocket-Version: 13\r\nAccept-Encoding: gzip, deflate, br\r\n'
           'Accept-Language: en-US,en;q=0.9\r\nSec-WebSocket-Key: %s\r\n\r\n') % (PATH, HOST, key)
    s.sendall(req.encode())
    resp = b''
    while b'\r\n\r\n' not in resp:
        chunk = s.recv(4096)
        if not chunk: raise RuntimeError('握手无响应')
        resp += chunk
    if b'101' not in resp.split(b'\r\n')[0]:
        raise RuntimeError('握手失败: %s' % resp.split(b'\r\n')[0].decode('utf-8', 'replace'))
    return s

def _send(s, payload, opcode=0x1):
    mask = os.urandom(4)
    data = payload.encode() if isinstance(payload, str) else payload
    n = len(data)
    hdr = bytes([0x80 | opcode])
    if n < 126: hdr += bytes([0x80 | n])
    elif n < 65536: hdr += bytes([0x80 | 126]) + struct.pack('>H', n)
    else: hdr += bytes([0x80 | 127]) + struct.pack('>Q', n)
    masked = bytes(b ^ mask[i % 4] for i, b in enumerate(data))
    s.sendall(hdr + mask + masked)

def _recv_exact(s, n):
    buf = b''
    while len(buf) < n:
        chunk = s.recv(n - len(buf))
        if not chunk: raise RuntimeError('连接中断')
        buf += chunk
    return buf

def _recv_frame(s):
    b1, b2 = _recv_exact(s, 2)
    opcode = b1 & 0x0F
    masked = b2 & 0x80
    ln = b2 & 0x7F
    if ln == 126: ln = struct.unpack('>H', _recv_exact(s, 2))[0]
    elif ln == 127: ln = struct.unpack('>Q', _recv_exact(s, 8))[0]
    mk = _recv_exact(s, 4) if masked else None
    data = _recv_exact(s, ln) if ln else b''
    if mk: data = bytes(b ^ mk[i % 4] for i, b in enumerate(data))
    return opcode, data

def synth(text, voice, dest):
    s = _ws_connect()
    cfg = ('X-Timestamp:%s\r\nContent-Type:application/json; charset=utf-8\r\nPath:speech.config\r\n\r\n'
           % _ts()) + json.dumps({"context": {"synthesis": {"audio": {
               "metadataoptions": {"sentenceBoundaryEnabled": "false", "wordBoundaryEnabled": "false"},
               "outputFormat": "audio-24khz-48kbitrate-mono-mp3"}}}})
    _send(s, cfg)
    ssml = ("<speak version='1.0' xmlns='http://www.w3.org/2001/10/synthesis' xml:lang='zh-CN'>"
            "<voice name='%s'><prosody pitch='+0Hz' rate='+0%%' volume='+0%%'>%s</prosody></voice></speak>"
            % (voice, text.replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;')))
    msg = ('X-RequestId:%s\r\nContent-Type:application/ssml+xml\r\nX-Timestamp:%s\r\nPath:ssml\r\n\r\n'
           % (uuid.uuid4().hex, _ts())) + ssml
    _send(s, msg)
    audio = b''
    s.settimeout(60)
    while True:
        op, data = _recv_frame(s)
        if op == 0x8: break
        if op == 0x9:
            _send(s, data, opcode=0xA); continue
        if op == 0x2:
            hl = struct.unpack('>H', data[:2])[0]
            audio += data[2 + hl:]
        elif op == 0x1:
            if 'Path:turn.end' in data.decode('utf-8', 'replace'): break
    s.close()
    if len(audio) < 500: raise RuntimeError('未收到有效音频(可能声音名无效或被限流)')
    with open(dest, 'wb') as f: f.write(audio)
    return len(audio)

p = argparse.ArgumentParser()
p.add_argument('--text'); p.add_argument('--voice', default='zh-CN-XiaoxiaoNeural')
p.add_argument('--out', default='/data/lemonbrain/nettools/tts_out.mp3')
a = p.parse_args()
text = clean(a.text)
if not text: die('缺少 text 参数')
voice = clean(a.voice, 'zh-CN-XiaoxiaoNeural')
dest = clean(a.out, '/data/lemonbrain/nettools/tts_out.mp3')
try:
    n = synth(text[:2000], voice, dest)
    out({"file": dest, "bytes": n, "voice": voice, "engine": "edge-tts(stdlib)"})
except Exception as e:
    die('Edge-TTS失败: %s' % e)