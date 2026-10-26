#!/usr/bin/env python3
"""Mirror tests. PowerShell is NOT available where this was written, so these tests (a) load the EXACT regex
strings from lib/PortableLlm.Core.ps1 and run them through Python's re (same syntax subset as .NET), and
(b) re-implement the small arithmetic/selection rules to check their intent. They do not execute the .ps1 code."""
import re, os, sys, math
HERE = os.path.dirname(os.path.abspath(__file__)); ROOT = os.path.dirname(HERE)
src = open(os.path.join(ROOT, 'lib', 'PortableLlm.Core.ps1'), encoding='ascii').read().splitlines()
RX = {}
for i, l in enumerate(src):
    m = re.match(r'\s*# REGEX:(\w+)\s*$', l)
    if m:
        v = re.match(r"\$PLlmRx_(\w+) = '(.*)'\s*$", src[i + 1]); assert v and v.group(1) == m.group(1), l
        RX[m.group(1)] = re.compile(v.group(2).replace("''", "'"))
fails = 0
def check(name, cond, detail=''):
    global fails
    print(('PASS  ' if cond else 'FAIL  ') + name + ('' if cond else '  -> ' + str(detail)))
    if not cond: fails += 1
def timing(line):
    for kind, key in (('Prompt', 'TimingPrompt'), ('Eval', 'TimingEval'), ('Total', 'TimingTotal')):
        m = RX[key].search(line)
        if m:
            g = m.groups(); ms = float(g[0]); tok = int(g[1]); rep = None
            if kind != 'Total' and g[2] is not None:
                try:
                    rep = float(g[2]); rep = None if (math.isnan(rep) or math.isinf(rep)) else rep
                except ValueError: rep = None
            comp = tok * 1000.0 / ms if ms > 0 and tok > 0 else None
            return dict(kind=kind, ms=ms, tok=tok, rep=rep, comp=comp)
lines = open(os.path.join(HERE, 'fixtures', 'server-startup-and-two-requests.log')).read().splitlines()
ev = [t for t in (timing(l) for l in lines) if t]
check('6 timing events parsed from fixture', len(ev) == 6, len(ev))
p, e, t = ev[0], ev[1], ev[2]
check('prompt line -> Prompt kind, 26 tok, 31.37 t/s', (p['kind'], p['tok'], p['rep']) == ('Prompt', 26, 31.37), p)
check('eval line -> Eval kind (NOT mistaken for prompt), 197 tok, 7.34 t/s', (e['kind'], e['tok'], e['rep']) == ('Eval', 197, 7.34), e)
check('total line -> 27683.85 ms / 223 tok', (t['kind'], t['ms'], t['tok']) == ('Total', 27683.85, 223), t)
check('prompt line is not matched by Eval regex', RX['TimingEval'].search(lines[6]) is None)
check('prompt tps recomputed from ms/tokens = 31.37', abs(p['comp'] - 31.374) < 0.01, p['comp'])
check('eval tps recomputed = 7.34 (report text said 7.30: 0.04 apart, flagged by launcher)', abs(e['comp'] - 7.336) < 0.01 and abs(e['comp'] - 7.30) > 0.011, e['comp'])
# timings exactly as written in the report (tokens-per-second NOT on the same line)
bare = timing('prompt eval time = 828.71 ms / 26 tokens'); check('bare prompt line parses, tps computed', bare and bare['rep'] is None and abs(bare['comp'] - 31.37) < 0.01, bare)
bare = timing('eval time = 26855.14 ms / 197 tokens'); check('bare eval line parses, tps computed', bare and bare['kind'] == 'Eval' and bare['rep'] is None, bare)
old = timing('       eval time =    1200.00 ms /    10 runs   (  120.00 ms per token,     8.33 tokens per second)'); check('"runs" wording (older builds) parses', old and old['tok'] == 10 and old['rep'] == 8.33, old)
z = timing('prompt eval time =       0.00 ms /     0 tokens (    -nan ms per token,      inf tokens per second)'); check('inf/nan -> no reported rate, no crash', z and z['rep'] is None and z['comp'] is None, z)
check('unrelated line ignored', timing('srv  log_server_r: request: POST /v1/chat/completions 127.0.0.1 200') is None)
# startup lines
si = RX['SystemInfo'].search(lines[3]); flags = dict((k, int(v)) for k, v in RX['SysInfoFlag'].findall(si.group(1)))
check('system_info flags parsed (AVX2=1, FMA=1, F16C=1, BMI2=1, no AVX512)', flags.get('AVX2') == 1 and flags.get('FMA') == 1 and flags.get('F16C') == 1 and flags.get('BMI2') == 1 and 'AVX512' not in flags, flags)
check('threads parsed', RX['Threads'].search(si.group(1)).group(1) == '4')
lb = RX['LoadBackend'].search(lines[1]); check('CPU backend path parsed', lb and lb.group(1) == 'CPU' and lb.group(2).endswith('ggml-cpu-haswell.dll'), lb and lb.groups())
check('variant name extracted: haswell', RX['Variant'].search(lb.group(2)).group(1) == 'haswell')
lb0 = RX['LoadBackend'].search(lines[0]); check('RPC backend line parsed as RPC (not CPU)', lb0.group(1) == 'RPC')
check('build line parsed', RX['BuildInfo'].search(lines[2]).group(1).startswith('10453 (3cb7ffb1a)'))
check('listening line detected', RX['Listening'].search(lines[4]) is not None)
check('CORS warning pattern matches the real string from llama-server-impl.dll', RX['CorsWarning'].search("CORS is set to allow all origins ('*') and no API key is set") is not None)
# session aggregation (mirror of Get-PLlmSessionStats)
reqs = [dict(pt=26, pms=828.71, gt=197, gms=26855.14), dict(pt=30, pms=866.5, gt=180, gms=22698.0)]
gavg = sum(r['gt'] for r in reqs) * 1000 / sum(r['gms'] for r in reqs); pavg = sum(r['pt'] for r in reqs) * 1000 / sum(r['pms'] for r in reqs)
check('session generation avg is token-weighted (7.61), distinct from latest request (7.93)', abs(gavg - 7.608) < 0.01 and abs(377 * 1000 / 49553.14 - gavg) < 1e-9, gavg)
check('session prompt avg weighted (~33.0) and never mixed with generation', abs(pavg - 33.0) < 0.1 and abs(pavg - gavg) > 20, pavg)
# build selection rules (mirror of Select-PLlmBuild)
def select(cands, host):
    rows = []
    for c in cands:
        if not c['exists']: rows.append(('MISSING', c)); continue
        miss = [f for f in c['min'] if host.get(f) is False]; unk = [f for f in c['min'] if host.get(f) is None]
        if c['verified']: st = 'REJECTED' if (miss or unk) else 'COMPATIBLE'
        else: st = 'REJECTED' if miss else 'UNVERIFIED'
        rows.append((st, c))
    ok = sorted([r for r in rows if r[0] == 'COMPATIBLE'], key=lambda r: -r[1]['pref'])
    if ok: return ok[0][1]['name'], 'VERIFIED'
    uv = [r for r in rows if r[0] == 'UNVERIFIED']
    return (uv[0][1]['name'], 'UNVERIFIED') if uv else (None, 'NONE')
bundle = dict(name='llama', exists=True, verified=True, min=['AVX2'], pref=100)
base = dict(name='llama\\baseline', exists=True, verified=False, min=[], pref=10)
check('AVX2 host + verified bundle -> VERIFIED bundle', select([bundle], {'AVX2': True}) == ('llama', 'VERIFIED'))
check('no-AVX2 host, only verified bundle -> NONE (nothing launched)', select([bundle], {'AVX2': False}) == (None, 'NONE'))
check('unknown AVX2 support is never treated as supported', select([bundle], {'AVX2': None}) == (None, 'NONE'))
check('no-AVX2 host falls back to unverified baseline build, flagged UNVERIFIED', select([bundle, base], {'AVX2': False}) == ('llama\\baseline', 'UNVERIFIED'))
check('unverified build is never reported as VERIFIED', select([dict(base, name='x')], {'AVX2': True})[1] == 'UNVERIFIED')
check('missing exe -> NONE', select([dict(bundle, exists=False)], {'AVX2': True}) == (None, 'NONE'))
print('\n%d failure(s)' % fails); sys.exit(1 if fails else 0)
