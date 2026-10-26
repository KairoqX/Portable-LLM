#!/usr/bin/env python3
"""Audit tests. Run from anywhere:  python3 tests/test_audit.py
Part A re-checks evidence claims against the real binaries (static; nothing is executed).
Part B mirrors the PowerShell verification/selection/backend rules in Python and runs them against the REAL manifest and
mutated temp copies of the real files. PowerShell was not available when this was written, so Part B tests the rules,
not the .ps1 code itself; tests/Run-Tests.ps1 repeats the scenarios against the actual PowerShell functions on Windows."""
import os, sys, re, json, hashlib, shutil, tempfile, subprocess, struct
HERE = os.path.dirname(os.path.abspath(__file__)); ROOT = os.path.dirname(HERE); LL = os.path.join(ROOT, 'llama')
sys.path.insert(0, os.path.join(ROOT, 'tools')); import pe_exports as ex, pe_min
fails = 0; skipped = []
def check(name, cond, detail=''):
    global fails; print(('PASS  ' if cond else 'FAIL  ') + name + ('' if cond else '  -> ' + str(detail)))
    fails += (not cond)
sha = lambda p: hashlib.sha256(open(p, 'rb').read()).hexdigest()
MANIFEST = os.path.join(LL, 'build-manifest.json'); M = json.load(open(MANIFEST))
have_objdump = shutil.which('objdump') is not None

print('--- Part A: evidence re-checks against the real files')
check('manifest sidecar digest matches manifest bytes', open(MANIFEST + '.sha256').read().split()[0] == sha(MANIFEST))
entries = M['core_modules'] + M['cpu_variants']
bad = [e['file'] for e in entries if not os.path.exists(os.path.join(LL, e['file'])) or sha(os.path.join(LL, e['file'])) != e['sha256']]
check('every manifest entry exists and its SHA-256 matches the shipped file', not bad, bad)
need = {'llama-server.exe', 'llama-server-impl.dll', 'llama-common.dll', 'ggml.dll', 'ggml-base.dll', 'llama.dll', 'mtmd.dll', 'ggml-rpc.dll'}
check('manifest lists the required modules incl. llama-server.exe, llama-server-impl.dll, llama-common.dll, ggml.dll', need <= {e['file'] for e in entries})
variants_on_disk = sorted(f for f in os.listdir(LL) if re.match(r'ggml-cpu-.*\.dll$', f))
check('manifest lists all %d ggml-cpu-*.dll on disk' % len(variants_on_disk), sorted(v['file'] for v in M['cpu_variants']) == variants_on_disk)
# import closure of llama-server.exe is fully covered
local = {f.lower(): f for f in os.listdir(LL)}; seen = set(); todo = ['llama-server.exe']
while todo:
    f = todo.pop()
    if f in seen or f not in local: continue
    seen.add(f); todo += [d.lower() for d in pe_min.parse(os.path.join(LL, local[f]))['imports'] if d.lower() in local]
check('static import closure of llama-server.exe is fully covered by the manifest', seen <= {e['file'].lower() for e in entries}, seen - {e['file'].lower() for e in entries})
check('llama\\ does not ship MSVCP140/VCRUNTIME140 (they must come from the PC)', 'msvcp140.dll' not in local and 'vcruntime140.dll' not in local)
signed = [f for f in os.listdir(LL) if f.lower().endswith(('.dll', '.exe')) and struct.unpack_from('<I', open(os.path.join(LL, f), 'rb').read(), 0)[0] and
          (lambda d: (lambda o: struct.unpack_from('<I', d, o + 112 + 8 * 4 + 4)[0])(struct.unpack_from('<I', d, 0x3c)[0] + 24))(open(os.path.join(LL, f), 'rb').read())]
check('only libomp140 carries an Authenticode signature (llama binaries are unsigned => no provenance from signatures)', signed == ['libomp140.x86_64.dll'], signed)
if have_objdump:
    ex_h = ex.exports_rva(os.path.join(LL, 'ggml-cpu-haswell.dll')); ex_x = ex.exports_rva(os.path.join(LL, 'ggml-cpu-x64.dll'))
    first = lambda dll, ex_, n: [l.split('\t', 1)[1].split()[0:2] for l in ex.dis(os.path.join(LL, dll), ex_[n], maxn=2)]
    check('haswell ggml_cpu_has_avx2 is a constant 1 (compile-time flag => system_info describes the DLL build)', first('ggml-cpu-haswell.dll', ex_h, 'ggml_cpu_has_avx2')[0] == ['mov', 'eax,0x1'])
    check('haswell ggml_cpu_has_avx512 is a constant 0', first('ggml-cpu-haswell.dll', ex_h, 'ggml_cpu_has_avx512')[0] == ['xor', 'eax,eax'])
    check('x64 ggml_cpu_has_avx2 is a constant 0', first('ggml-cpu-x64.dll', ex_x, 'ggml_cpu_has_avx2')[0] == ['xor', 'eax,eax'])
    sc = ' '.join(l.split('\t', 1)[1] for l in ex.dis(os.path.join(LL, 'ggml-cpu-haswell.dll'), ex_h['ggml_backend_score'], maxn=21))
    check('haswell scorer tests leaf1.ECX mask 0x20101000 (FMA|SSE4.2|F16C), AVX bit 0x10000000, BMI2 0x100, AVX2 via (x*2)&0x40',
          all(t in sc for t in ('0x20101000', '0x10000000', 'test   eax,0x100', 'and    eax,0x40')), sc[:200])
    check('scorer function contains no XGETBV (CPUID bits only; OS state not checked by it)', 'xgetbv' not in sc)
    dll = subprocess.run(['objdump', '-d', '-M', 'intel', '--no-show-raw-insn', os.path.join(LL, 'ggml.dll')], capture_output=True, text=True).stdout
    check('ggml.dll loader: call score; cmp eax,best; jle skip (strictly-greater-wins, 0 never wins)',
          re.search(r'call\s+rax\s+\S*\s*\n?\s*[0-9a-f]+:\tcmp\s+eax,DWORD PTR \[rbp\+0x308\]\s+[0-9a-f]+:\tjle', dll.replace('\n', ' \n')) is not None or
          ('call   rax' in dll and 'cmp    eax,DWORD PTR [rbp+0x308]' in dll and 'jle' in dll))
else: skipped.append('Part A disassembly checks (objdump missing)')

print('--- Part B: mirrored rules on the real manifest + mutated copies')
HEX64 = re.compile(r'^[0-9a-fA-F]{64}$'); ALLOWED = {'SSE42','AVX','F16C','AVX2','BMI2','FMA','AVX512','AVX_VNNI','AVX512_VBMI','AVX512_VNNI','AVX512_BF16','AMX_TILE','AMX_INT8'}
def schema(m):                                           # mirror of Test-PLlmManifestSchema
    if not m: return ['manifest is empty']
    e = []
    if m.get('schema') != 1: e.append('schema')
    core = m.get('core_modules') or []; vs = m.get('cpu_variants') or []
    if not core: e.append('core_modules is missing or empty')
    names = {}
    for x in core + vs:
        f = x.get('file') or ''
        if not f: e.append('entry without a file name'); continue
        if re.search(r'[\\/:]', f) or '..' in f: e.append('unsafe file name')
        if not HEX64.match(x.get('sha256') or ''): e.append('bad sha256')
        if f.lower() in names: e.append('duplicate')
        names[f.lower()] = 1
    for r in ('llama-server.exe', 'ggml.dll', 'ggml-base.dll', 'llama.dll'):
        if r not in names: e.append('required module not listed: ' + r)
    for f in m.get('min_host_features') or []:
        if f not in ALLOWED: e.append('unknown min_host_features entry')
    return e
def verify(d, m, mpath=None):                            # mirror of Test-PLlmManifest
    p = ['invalid manifest: ' + x for x in schema(m)]
    if mpath:
        side = mpath + '.sha256'
        if os.path.exists(side):
            if open(side).read().split()[0].lower() != sha(mpath): p.append('sidecar mismatch')
        else: p.append('no sidecar')
    listed = set()
    for x in ((m or {}).get('core_modules') or []) + ((m or {}).get('cpu_variants') or []):
        f = x.get('file') or ''
        if not f or re.search(r'[\\/:]', f): continue
        listed.add(f.lower()); fp = os.path.join(d, f)
        if not os.path.exists(fp): p.append('missing file: ' + f); continue
        if sha(fp) != (x.get('sha256') or '').lower(): p.append('hash differs: ' + f)
    for f in os.listdir(d):
        if re.match(r'ggml-.*\.dll$', f, re.I) and f.lower() not in listed: p.append('unlisted backend DLL: ' + f)
    return p
def sandbox():
    t = tempfile.mkdtemp(prefix='pllm-audit-')
    for f in os.listdir(LL): os.symlink(os.path.join(LL, f), os.path.join(t, f))
    return t
def mutate_file(t, name, data=b'tampered'):             # replace symlink by a modified COPY (never touches the real file)
    p = os.path.join(t, name); src = os.path.realpath(p); os.remove(p); shutil.copy(src, p); open(p, 'ab').write(data)
def copy_manifest(t, mutate=None, keep_sidecar=True):
    mp = os.path.join(t, 'build-manifest.json'); os.remove(mp); m = json.load(open(MANIFEST))
    if mutate: mutate(m)
    txt = json.dumps(m, indent=2) + '\n'; open(mp, 'w').write(txt)
    sp = mp + '.sha256'; os.remove(sp)
    if keep_sidecar: open(sp, 'w').write(open(MANIFEST + '.sha256').read())     # original digest: proves detection of edits
    return mp, m
t = sandbox(); mp = os.path.join(t, 'build-manifest.json')
check('untouched bundle: no problems', verify(t, json.load(open(mp)), mp) == [], verify(t, json.load(open(mp)), mp))
t = sandbox(); mutate_file(t, 'ggml-cpu-haswell.dll'); r = verify(t, M, os.path.join(t, 'build-manifest.json'))
check('hash mismatch (variant DLL) detected', any('hash differs: ggml-cpu-haswell.dll' in x for x in r), r)
for core in ('llama-server.exe', 'llama-server-impl.dll', 'llama-common.dll', 'ggml.dll'):
    t = sandbox(); mutate_file(t, core); r = verify(t, M, os.path.join(t, 'build-manifest.json'))
    check('hash mismatch (%s) detected' % core, any('hash differs: ' + core in x for x in r), r)
t = sandbox(); os.remove(os.path.join(t, 'llama-server-impl.dll')); r = verify(t, M, os.path.join(t, 'build-manifest.json'))
check('missing core DLL detected', any('missing file: llama-server-impl.dll' in x for x in r), r)
t = sandbox(); os.remove(os.path.join(t, 'ggml-cpu-zen4.dll')); r = verify(t, M, os.path.join(t, 'build-manifest.json'))
check('missing CPU variant DLL detected', any('missing file: ggml-cpu-zen4.dll' in x for x in r), r)
for extra in ('ggml-cpu-evil.dll', 'ggml-vulkan.dll', 'ggml-cuda.dll'):
    t = sandbox(); open(os.path.join(t, extra), 'wb').write(b'MZ'); r = verify(t, M, os.path.join(t, 'build-manifest.json'))
    check('unexpected loader-scanned DLL (%s) invalidates verification' % extra, any('unlisted backend DLL: ' + extra in x for x in r), r)
t = sandbox(); mp, m = copy_manifest(t, lambda m: m.update(core_modules=[], cpu_variants=[])); r = verify(t, m, mp)
check('manifest with empty module lists is NOT verified (the old code accepted this)', r != [], r)
t = sandbox(); mp, m = copy_manifest(t, lambda m: None, keep_sidecar=True); open(mp, 'w').write('{}\n'); r = verify(t, {}, mp)
check('"{}" manifest is NOT verified', r != [], r)
t = sandbox(); mp, m = copy_manifest(t, lambda m: m.update(schema=99)); r = verify(t, m, mp); check('unsupported schema rejected', any('schema' in x for x in r), r)
t = sandbox(); mp, m = copy_manifest(t, lambda m: m['core_modules'][0].update(file='..\\evil.dll')); r = verify(t, m, mp); check('path-traversal file name rejected', any('unsafe file name' in x for x in r), r)
t = sandbox(); mp, m = copy_manifest(t, lambda m: m['core_modules'][0].update(sha256='zz')); r = verify(t, m, mp); check('malformed SHA-256 rejected', any('bad sha256' in x for x in r), r)
t = sandbox(); mp, m = copy_manifest(t, lambda m: m.update(min_host_features=['AVX2', 'MAGIC'])); r = verify(t, m, mp); check('unknown min_host_features entry rejected', any('min_host_features' in x for x in r), r)
t = sandbox(); mp, m = copy_manifest(t, lambda m: m.update(min_host_features=[])); r = verify(t, m, mp)
check('manifest edited to drop the AVX2 minimum is caught only via the sidecar (and the sidecar is itself unauthenticated)', any('sidecar mismatch' in x for x in r), r)
t = sandbox(); mp, m = copy_manifest(t, lambda m: None, keep_sidecar=False); r = verify(t, m, mp); check('missing sidecar => not verified', any('no sidecar' in x for x in r), r)
# an attacker who edits manifest AND sidecar defeats the check: state the limit instead of hiding it
t = sandbox(); mutate_file(t, 'llama-server-impl.dll'); mp, m = copy_manifest(t, lambda m: [e.update(sha256=sha(os.path.join(t, 'llama-server-impl.dll'))) for e in m['core_modules'] if e['file'] == 'llama-server-impl.dll'], keep_sidecar=False)
open(mp + '.sha256', 'w').write('%s  build-manifest.json\n' % sha(mp)); r = verify(t, m, mp)
check('LIMIT (expected to pass verification): attacker who rewrites binary + manifest + sidecar is NOT detected -> integrity only, no provenance', r == [], r)

# --- prediction rules (mirror of Resolve-PLlmHostFeatures / Get-PLlmPredictedVariant)
TABLE = {v['variant']: v['declared_requires'] for v in M['cpu_variants']}
def predict(scores):
    if scores is None: return None
    best = max([s for s in scores.values() if s], default=0)
    if best <= 0: return None
    top = [k for k, s in scores.items() if s == best]; return top[0] if len(top) == 1 else None
def features(pf, scores):
    f = {k: None for k in ('SSE42','AVX','F16C','AVX2','BMI2','FMA','AVX512')}
    for k in ('SSE42','AVX','AVX2','AVX512'):
        if pf.get(k) is not None: f[k] = bool(pf[k])
    for v, s in (scores or {}).items():
        if s and s > 0:
            for r in TABLE.get(v, []): f[r] = True
    for k in ('SSE42','AVX','AVX2','AVX512'):
        if pf.get(k) is False: f[k] = False
    return f
zen2 = {'x64': 1, 'sse42': 2, 'sandybridge': 6, 'ivybridge': 14, 'piledriver': 30, 'haswell': 64, 'skylakex': 0, 'zen4': 0, 'sapphirerapids': 0}   # synthetic numbers; only ordering/zeros matter
check('prediction is derived from scores (Zen2-like => haswell) and not hard-coded', predict(zen2) == 'haswell' and predict(dict(zen2, haswell=0)) == 'piledriver' and predict(dict(zen2, zen4=900)) == 'zen4')
check('unsupported CPU (every score 0) => no prediction', predict({k: 0 for k in zen2}) is None)
check('scorer unavailable => no prediction (UNKNOWN), never a guess', predict(None) is None)
check('tie for top score => no prediction', predict({'a': 5, 'b': 5, 'c': 1}) is None)
f = features({'AVX2': False, 'AVX': True}, zen2); check('Windows says no AVX2 but scorer accepted haswell => AVX2 treated as UNAVAILABLE', f['AVX2'] is False)
f = features({}, None); check('no Windows data and no scorer => AVX2 unknown (None), not assumed', f['AVX2'] is None)
f = features({'AVX2': True}, None); check('FMA/BMI2/F16C stay unknown when only the AVX2 flag is known', f['FMA'] is None and f['BMI2'] is None and f['F16C'] is None)
def select(rows, host):                                  # mirror of Select-PLlmBuild
    out = []
    for c in rows:
        if not c['exists']: out.append('MISSING'); continue
        miss = [x for x in c['min'] if host.get(x) is False]; unk = [x for x in c['min'] if host.get(x) is None]
        out.append(('REJECTED' if (miss or unk) else 'COMPATIBLE') if c['verified'] else ('REJECTED' if miss else 'UNVERIFIED'))
    return out
b = dict(exists=True, verified=True, min=['AVX2'])
check('unsupported CPU (no AVX2) => bundle REJECTED, nothing launched', select([b], {'AVX2': False}) == ['REJECTED'])
check('unknown AVX2 support => REJECTED (unknown is never "supported")', select([b], {'AVX2': None}) == ['REJECTED'])
check('failed manifest verification => UNVERIFIED, never COMPATIBLE', select([dict(b, verified=False)], {'AVX2': True}) == ['UNVERIFIED'])

# --- runtime backend identification (mirror of Get-PLlmResolvedBackend) and log-format regexes taken from the PS source
def resolved(seen):
    paths = {x.lower() for x in seen}
    return seen[0] if len(paths) == 1 else None
check('no runtime backend line => UNKNOWN (None), even if host CPU/DLLs on disk suggest haswell', resolved([]) is None)
check('one logged CPU backend path => identified from that line only', resolved([r'C:\x\ggml-cpu-haswell.dll', r'c:\x\ggml-cpu-haswell.dll']) is not None)
check('two different CPU backend paths logged => ambiguous => UNKNOWN', resolved([r'C:\x\ggml-cpu-haswell.dll', r'C:\x\ggml-cpu-x64.dll']) is None)
src = open(os.path.join(ROOT, 'lib', 'PortableLlm.Core.ps1')).read()
lis = re.search(r"\$PLlmRx_Listening = '(.*)'", src).group(1); LIS = re.compile(lis)
for line, want in (('srv  start: listening on 127.0.0.1:8080', True), ('srv  start: listening on http://127.0.0.1:8080', True), ('main: server is listening on http://127.0.0.1:8080', True), ('srv  load: loading model', False)):
    check('listening regex on "%s" -> %s' % (line, want), bool(LIS.search(line)) == want)
for need in ('Get-PLlmResolvedBackend', 'Test-PLlmManifestSchema', 'BackendAmbiguous'):
    check('source contains %s' % need, need in src + open(os.path.join(ROOT, 'monitor.ps1')).read())
check("no hard-coded 'haswell' in launcher/monitor logic", 'haswell' not in open(os.path.join(ROOT, 'launcher.ps1')).read().replace('haswell.dll', '').replace('ggml-cpu-haswell', '').replace("(e.g. haswell)", ''), 'found')
print('\n%d failure(s)%s' % (fails, ('; not run: ' + '; '.join(skipped)) if skipped else '')); sys.exit(1 if fails else 0)
