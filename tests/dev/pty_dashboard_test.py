#!/usr/bin/env python3
"""Interactive dashboard test through a real pseudo-terminal (Linux/macOS only; needs `pip install pyte` and PowerShell 7).
Drives the real monitor loop against tests/dev/fakeserver.sh and a fake /health endpoint, presses keys, resizes the window,
and checks what a terminal emulator actually shows.  It is NOT a Windows test.   Usage: python3 tests/dev/pty_dashboard_test.py [pwsh]"""
import os, pty, sys, time, struct, fcntl, termios, select, re, threading, http.server, subprocess, signal
import pyte
HERE = os.path.dirname(os.path.abspath(__file__)); PWSH = sys.argv[1] if len(sys.argv) > 1 else 'pwsh'
PORT = 18080; fails = 0
def check(name, cond, detail=''):
    global fails; print(('PASS  ' if cond else 'FAIL  ') + name + ('' if cond else '  -> ' + str(detail))); fails += (not cond)

def run(scenario, health_after=0.0):
    env = dict(os.environ, DOTNET_SYSTEM_GLOBALIZATION_INVARIANT='1', TERM='xterm-256color', FAKE_EXIT_AFTER='60')
    for k in ('PORTABLE_LLM_UI', 'NO_COLOR', 'PORTABLE_LLM_ASCII'): env.pop(k, None)
    if scenario in ('health', 'resize'): env['FAKE_NO_IDLE'] = '1'
    if scenario == 'nocolor': env['NO_COLOR'] = '1'
    if scenario == 'ascii': env['PORTABLE_LLM_ASCII'] = '1'
    if scenario == 'crash': env.update(FAKE_EXIT_AFTER='3', FAKE_EXIT_CODE='3')
    t0 = time.time()
    class H(http.server.BaseHTTPRequestHandler):
        def do_GET(s):
            code = 503 if time.time() - t0 < health_after else 200
            s.send_response(code); s.send_header('Content-Length', '2'); s.end_headers(); s.wfile.write(b'{}')
        def log_message(*a): pass
    srv = http.server.HTTPServer(('127.0.0.1', PORT), H); threading.Thread(target=srv.serve_forever, daemon=True).start()
    W, Hh = 120, 30; screen = pyte.Screen(W, Hh); stream = pyte.ByteStream(screen); raw = bytearray()
    pid, fd = pty.fork()
    if pid == 0:
        os.environ.update(env); os.execv(PWSH, [PWSH, '-NoProfile', '-File', os.path.join(HERE, 'drive_monitor.ps1'), '-Port', str(PORT)])
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack('HHHH', Hh, W, 0, 0))
    def pump(sec):
        end = time.time() + sec
        while time.time() < end:
            r, _, _ = select.select([fd], [], [], 0.1)
            if r:
                try: d = os.read(fd, 65536)
                except OSError: return
                if not d: return
                raw.extend(d); stream.feed(d)
    text = lambda: '\n'.join(screen.display)
    shots = {}
    pump(2.5); shots['early'] = text()
    if scenario == 'health': pump(3.0); shots['late'] = text()
    if scenario == 'resize':
        pump(1.0); os.write(fd, b'd'); pump(1.2); shots['diag'] = text()
        fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack('HHHH', 24, 80, 0, 0)); os.kill(pid, signal.SIGWINCH); screen.resize(24, 80); pump(1.5); shots['small'] = text()
        os.write(fd, b'l'); pump(1.0); shots['log'] = text()
    if scenario == 'crash': pump(3.5); shots['crash'] = text()
    os.write(fd, {'ctrlc': b'\x03', 'crash': b'q'}.get(scenario, b'q')); pump(2.5)
    srv.shutdown(); srv.server_close()
    code = None; t = time.time()
    while time.time() - t < 6:
        w, s = os.waitpid(pid, os.WNOHANG)
        if w: code = os.waitstatus_to_exitcode(s); break
        pump(0.2)
    s = raw.decode('utf8', 'replace'); dash = s[s.find('\x1b[?1049h'):s.rfind('\x1b[?1049l')]
    left = subprocess.run("ps -ef | grep fakeserver.sh | grep -v grep | wc -l", shell=True, capture_output=True, text=True).stdout.strip()
    return dict(shots=shots, code=code, raw=s, dash=dash, leftover=left)

r = run('health', health_after=4.0)
check('health 503 -> header shows "Loading Model"', 'Loading Model' in r['shots']['early'])
check('health 200 -> header shows "Ready"', re.search(r'Ready', r['shots']['late']) is not None)
check('quit: process exited, alt screen entered and left, cursor shown again', r['code'] == 0 and '\x1b[?1049h' in r['raw'] and '\x1b[?1049l' in r['raw'] and r['raw'].rfind('\x1b[?25h') > r['raw'].rfind('\x1b[?25l'), r['code'])
check('quit: no server process left behind', r['leftover'] == '0', r['leftover'])
check('quit: summary printed after leaving the dashboard', 'Stopped by you' in r['raw'][r['raw'].rfind('\x1b[?1049l'):])
r = run('resize', health_after=0.0)
check("'d' shows the diagnostics panel", 'DIAGNOSTICS' in r['shots']['diag'] and 'Orphan guard' in r['shots']['diag'])
check('resize to 80x24 re-lays out (single column, nothing wider than 79)', 'MODEL' in r['shots']['small'] and max(len(l.rstrip()) for l in r['shots']['small'].split('\n')) <= 79)
check("'l' shows the log path and does not open anything", 'session.log' in r['shots']['log'] and 'press L again' in r['shots']['log'])
r = run('ctrlc')
check('Ctrl+C quits cleanly: exit 0, no leftover server', r['code'] == 0 and r['leftover'] == '0', (r['code'], r['leftover']))
r = run('nocolor')
check('NO_COLOR: dashboard emits no SGR color codes', len(re.findall(r'\x1b\[[0-9;]*m', r['dash'])) == 0)
r = run('ascii')
check('PORTABLE_LLM_ASCII=1: dashboard is pure ASCII', all(ord(c) < 128 for c in r['dash']))
r = run('crash')
check('server crash: dashboard stays up showing Error and the actionable hint', 'Error' in r['shots']['crash'] and 'port is already in use' in r['shots']['crash'])
check('server crash: server exit code 3 is not hidden (summary says exit code 3 or failure)', r['code'] == 0 and 'Exit code: 3' in r['raw'] or 'EXIT CODE: 3' in r['raw'])
print('\n%d failure(s)' % fails); sys.exit(1 if fails else 0)
