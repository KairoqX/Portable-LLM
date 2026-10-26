#!/usr/bin/env python3
"""
Dev-side tool (NOT needed at runtime). Statically analyses a llama.cpp Windows bundle and writes
llama/build-manifest.json, which the launcher uses to check that the files on disk are the exact
files that were analysed (SHA-256) and to read their ISA requirements.

Requires: python3, GNU objdump (binutils) able to read pei-x86-64. No network.
Usage:    python3 tools/analyze_bundle.py llama  > llama/build-manifest.json

What this CAN establish: which instruction classes are present in each module's machine code,
and (for the per-ISA ggml-cpu-<variant>.dll files) whether that matches the variant's declared name.
What it can NOT establish: that a given instruction is never executed on a CPU lacking it.
"""
import sys, os, re, json, hashlib, subprocess, datetime, collections

# Upstream ggml CMake variant names (GGML_CPU_ALL_VARIANTS). Declared requirements are the project's
# naming convention; the analysis below cross-checks them against the instructions actually present.
BASE = ['SSE42', 'AVX', 'F16C', 'AVX2', 'BMI2', 'FMA']
DECLARED = collections.OrderedDict([
    ('x64',            []),
    ('sse42',          ['SSE42']),
    ('sandybridge',    ['SSE42', 'AVX']),
    ('ivybridge',      ['SSE42', 'AVX', 'F16C']),
    ('piledriver',     ['SSE42', 'AVX', 'F16C', 'FMA']),
    ('haswell',        BASE),
    ('alderlake',      BASE + ['AVX_VNNI']),
    ('skylakex',       BASE + ['AVX512']),
    ('cannonlake',     BASE + ['AVX512', 'AVX512_VBMI']),
    ('cascadelake',    BASE + ['AVX512', 'AVX512_VNNI']),
    ('icelake',        BASE + ['AVX512', 'AVX512_VBMI', 'AVX512_VNNI']),
    ('cooperlake',     BASE + ['AVX512', 'AVX512_VNNI', 'AVX512_BF16']),
    ('zen4',           BASE + ['AVX512', 'AVX512_VBMI', 'AVX512_VNNI', 'AVX512_BF16']),
    ('sapphirerapids', BASE + ['AVX512', 'AVX512_VBMI', 'AVX512_VNNI', 'AVX512_BF16', 'AMX_TILE', 'AMX_INT8']),
])
CORE = ['llama-server.exe', 'llama-server-impl.dll', 'llama-common.dll', 'llama.dll', 'ggml.dll',
        'ggml-base.dll', 'mtmd.dll', 'ggml-rpc.dll', 'libomp140.x86_64.dll']
VEX_SKIP = ('verr', 'verw', 'vmcall')
INSN = re.compile(r'^\s*([0-9a-f]+):\t(?:(?:rep\w*|lock|bnd|notrack|data16|cs|ds|es|fs|gs|addr32)\s+)*([a-z0-9_.]+)\s*(.*)$')

def sha256(p):
    h = hashlib.sha256()
    with open(p, 'rb') as f:
        for b in iter(lambda: f.read(1 << 20), b''):
            h.update(b)
    return h.hexdigest()

def disasm(path):
    out = subprocess.run(['objdump', '-d', '-M', 'intel', '--no-show-raw-insn', path],
                         capture_output=True, text=True, check=True).stdout
    for line in out.splitlines():
        m = INSN.match(line)
        if m:
            yield int(m.group(1), 16), m.group(2), m.group(3)

def classify(mn, ops):
    f = set()
    if mn.startswith('v') and mn not in VEX_SKIP: f.add('AVX')
    if re.search(r'\bzmm\d+|\b[xy]mm(1[6-9]|2\d|3[01])\b|\bk[0-7]\b', ops): f.add('AVX512')
    if re.match(r'vfn?m(add|sub)', mn) or mn.startswith(('vfmaddsub', 'vfmsubadd')): f.add('FMA')
    if mn in ('vcvtph2ps', 'vcvtps2ph'): f.add('F16C')
    if mn.startswith('vp') and 'ymm' in ops and not mn.startswith(('vpdp', 'vpopcnt')):
        f.add('AVX2')                     # 256-bit integer VEX op => AVX2
    if mn.startswith('vpdp'): f.add('VNNI')
    if mn in ('vdpbf16ps', 'vcvtneps2bf16', 'vcvtne2ps2bf16'): f.add('AVX512_BF16')
    if mn in ('pdep', 'pext', 'bzhi', 'mulx', 'rorx', 'sarx', 'shlx', 'shrx'): f.add('BMI2')
    if mn.startswith(('amx', 'tile', 'tdp', 'ldtilecfg', 'sttilecfg')): f.add('AMX')
    if mn in ('pmulld', 'pminsd', 'pmaxsd', 'ptest', 'pblendw', 'pblendvb', 'blendvps', 'roundps',
              'roundss', 'roundsd', 'pextrd', 'pinsrd', 'pmovzxbw', 'pmovsxbw', 'packusdw', 'dpps'): f.add('SSE41')
    if mn in ('pcmpestri', 'pcmpistri', 'pcmpgtq', 'crc32'): f.add('SSE42')
    return f

def analyse(path):
    feats = collections.Counter(); n = 0
    vex = []                                    # (addr, mnemonic, has_ymm_int)
    for a, mn, ops in disasm(path):
        n += 1
        for ft in classify(mn, ops): feats[ft] += 1
        if mn.startswith('v') and mn not in VEX_SKIP:
            vex.append((a, 'vp' in mn[:2] and 'ymm' in ops and not mn.startswith(('vpdp', 'vpopcnt'))))
    regions = []                                # clusters of VEX code, gap < 0x400 bytes
    for a, ymm_int in vex:
        if regions and a - regions[-1]['end'] < 0x400:
            r = regions[-1]; r['end'] = a; r['vex_instructions'] += 1; r['ymm_integer_ops'] += int(ymm_int)
        else:
            regions.append({'start': a, 'end': a, 'vex_instructions': 1, 'ymm_integer_ops': int(ymm_int)})
    for r in regions: r['start'] = hex(r['start']); r['end'] = hex(r['end'])
    return n, dict(sorted(feats.items())), regions

def main(d):
    mods, variants = [], []
    for name in CORE:
        p = os.path.join(d, name)
        if not os.path.exists(p): continue
        n, f, reg = analyse(p)
        mods.append({'file': name, 'sha256': sha256(p), 'bytes': os.path.getsize(p),
                     'instructions_scanned': n, 'observed_isa': f, 'vex_regions': reg})
        print('scanned', name, file=sys.stderr)
    for v, req in DECLARED.items():
        name = 'ggml-cpu-%s.dll' % v
        p = os.path.join(d, name)
        if not os.path.exists(p): continue
        n, f, reg = analyse(p)
        o = set(f)
        # consistency of observed instructions with the declared requirement list
        problems = []
        if 'AVX512' in o and 'AVX512' not in req: problems.append('uses AVX-512 but not declared')
        if 'FMA' in o and 'FMA' not in req: problems.append('uses FMA but not declared')
        if 'F16C' in o and 'F16C' not in req: problems.append('uses F16C but not declared')
        if 'BMI2' in o and 'BMI2' not in req: problems.append('uses BMI2 but not declared')
        if 'AMX' in o and 'AMX_INT8' not in req: problems.append('uses AMX but not declared')
        if 'FMA' in req and 'FMA' not in o: problems.append('declared FMA but none observed')
        if 'AVX512' in req and 'AVX512' not in o: problems.append('declared AVX-512 but none observed')
        variants.append({'variant': v, 'file': name, 'sha256': sha256(p), 'bytes': os.path.getsize(p),
                         'declared_requires': req, 'observed_isa': f,
                         'observed_consistent_with_declared': not problems, 'consistency_notes': problems})
        print('scanned', name, file=sys.stderr)
    manifest = {
        'schema': 1,
        'generated_utc': datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
        'generator': 'tools/analyze_bundle.py (static disassembly with GNU objdump; no execution)',
        'llama_cpp': {'build': '10453', 'commit': '3cb7ffb1a', 'version_string': '0.1.0-dev',
                      'compiler': 'Clang 20.1.8', 'target': 'Windows x86_64',
                      'evidence': 'ASCII strings found in llama-common.dll, llama-server-impl.dll, ggml-base.dll, llama.dll'},
        'layout': 'ggml-backend-dl: one ggml-cpu-<variant>.dll per ISA level; ggml.dll loads all, calls each '
                  'ggml_backend_score() and uses the highest non-zero score',
        'preference': 100,
        'min_host_features': ['AVX2'],
        'min_host_features_basis': (
            'CONSERVATIVE. llama-server-impl.dll and llama-common.dll each contain a contiguous routine of ~400 '
            'instructions made entirely of VEX encodings including 256-bit integer ops (AVX2); no CPUID/feature '
            'guard was found at its call site. Other VEX regions in generic modules look like MSVC STL vectorised '
            'helpers; the ones traced (ggml-cpu-x64, ggml-cpu-sse42, ggml-rpc, mtmd) branch on a flag populated '
            'by CPUID/XGETBV. Not every region was traced, so AVX2 is used as the minimum for this bundle.'),
        'supports_cli': ['--cors-origins', '--cors-methods', '--cors-headers', '--cors-credentials', '--api-key'],
        'supports_cli_evidence': 'ASCII option strings present in llama-common.dll / llama-server-impl.dll',
        'core_modules': mods,
        'cpu_variants': variants,
        'limitations': [
            'Static analysis shows which instruction classes are PRESENT, not which are EXECUTED on a given CPU.',
            'Declared variant requirements follow upstream ggml naming; AVX512_VBMI / AVX_VNNI / AMX_TILE were not individually confirmed.',
            'No Windows execution was performed while producing this manifest.'],
    }
    json.dump(manifest, sys.stdout, indent=2); print()

if __name__ == '__main__':
    main(sys.argv[1] if len(sys.argv) > 1 else 'llama')
