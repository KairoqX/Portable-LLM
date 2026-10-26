#!/usr/bin/env python3
"""Dev-side static call-graph tracer. Usage: trace_callers.py <dll> <hex_va_inside_target_function> [more...]
Uses .pdata (exact function bounds), direct call/jmp targets, base-relocation function pointers (vtables) and
RIP-relative address-of references. It reports what it can see; indirect calls through registers are NOT resolved,
so "no caller found" never means "never called"."""
import sys, struct, subprocess, re, bisect, collections
IMG = 0x180000000
def load(path):
    d = open(path, 'rb').read(); e = struct.unpack_from('<I', d, 0x3c)[0]; o = e + 24
    nsec = struct.unpack_from('<H', d, e + 6)[0]; so = o + struct.unpack_from('<H', d, e + 20)[0]
    ddo = o + 112
    secs = [struct.unpack_from('<8sIIII', d, so + 40 * i) for i in range(nsec)]
    img = struct.unpack_from('<Q', d, o + 24)[0]
    dd = lambda i: struct.unpack_from('<II', d, ddo + 8 * i)
    def r2o(r):
        for n, vs, va, rs, rp in secs:
            if va <= r < va + max(vs, rs): return r - va + rp
    return d, secs, img, dd, r2o
def main(path, targets):
    d, secs, img, dd, r2o = load(path)
    pr, ps = dd(3); funcs = []
    for i in range(ps // 12):
        b, en, u = struct.unpack_from('<III', d, r2o(pr) + 12 * i)
        funcs.append((img + b, img + en))
    funcs.sort(); starts = [f[0] for f in funcs]
    def fn_of(va):
        i = bisect.bisect_right(starts, va) - 1
        return funcs[i][0] if i >= 0 and va < funcs[i][1] else None
    # disassemble .text
    out = subprocess.run(['objdump', '-d', '-M', 'intel', '--no-show-raw-insn', path], capture_output=True, text=True).stdout
    pat = re.compile(r'^\s*([0-9a-f]+):\t(\S+)\s*(.*)$'); ins = []
    for l in out.splitlines():
        m = pat.match(l)
        if m: ins.append((int(m.group(1), 16), m.group(2), m.group(3)))
    callers = collections.defaultdict(set); addr_taken = collections.defaultdict(set)
    for a, mn, ops in ins:
        if mn in ('call', 'jmp'):
            m = re.match(r'0x([0-9a-f]+)$', ops.strip())
            if m:
                t = fn_of(int(m.group(1), 16)); s = fn_of(a)
                if t and s and t != s: callers[t].add(('call' if mn == 'call' else 'tailjmp', s))
        m = re.search(r'# 0x([0-9a-f]+)', ops)
        if mn == 'lea' and m:
            t = int(m.group(1), 16)
            if t in set(starts): addr_taken[t].add(('lea', fn_of(a)))
    br, bs = dd(5); p = r2o(br); end = p + bs
    while p < end:
        page, blk = struct.unpack_from('<II', d, p)
        for k in range((blk - 8) // 2):
            ent = struct.unpack_from('<H', d, p + 8 + 2 * k)[0]
            if ent >> 12 == 10:
                loc = page + (ent & 0xfff); off = r2o(loc)
                if off:
                    v = struct.unpack_from('<Q', d, off)[0]
                    if v in set(starts): addr_taken[v].add(('data-pointer @rva %#x' % loc, None))
        p += blk
    # CRT feature variables: find cpuid-init function and the DWORDs it stores small constants into
    init = [fn_of(a) for a, mn, _ in ins if mn == 'cpuid']; init = set(x for x in init if x)
    consts = collections.Counter()
    for a, mn, ops in ins:
        if fn_of(a) in init and mn == 'mov':
            m = re.match(r'DWORD PTR \[rip\+0x[0-9a-f]+\],0x([0-9a-f]+)\s+# 0x([0-9a-f]+)', ops)
            if m and int(m.group(1), 16) in (1, 2, 3, 5, 6): consts[int(m.group(2), 16)] += 1
    isa_vars = {v for v, c in consts.items() if c >= 1}
    readers = collections.defaultdict(set)
    for a, mn, ops in ins:
        m = re.search(r'# 0x([0-9a-f]+)', ops)
        if m and int(m.group(1), 16) in isa_vars and mn in ('cmp', 'mov', 'test', 'bt') and fn_of(a) not in init:
            readers[fn_of(a)].add(hex(int(m.group(1), 16)))
    print('module', path, '| functions in .pdata:', len(funcs), '| CRT cpu-init fn(s):', [hex(x) for x in init])
    print('CRT ISA variables (written by init):', [hex(v) for v in sorted(isa_vars)], '| functions that read them outside init:', len(readers))
    strings = {}
    for t in targets:
        f = fn_of(int(t, 16)); print('\n=== target', t, '-> function %#x..%#x' % next(x for x in funcs if x[0] == f) if f else '-> none')
        if not f: continue
        seen = {f}; level = [f]
        for depth in range(1, 8):
            nxt = []
            for fn in level:
                refs = sorted(callers.get(fn, set()), key=str) + sorted(addr_taken.get(fn, set()), key=str)
                for kind, s in refs:
                    tag = '' if (s is None) else (' [reads CRT ISA var]' if s in readers else '')
                    print('%s%#x  <-  %s %s%s' % ('  ' * depth, fn, kind, hex(s) if s else '', tag))
                    if s and s not in seen: seen.add(s); nxt.append(s)
                if not refs: print('%s%#x  <-  (no direct caller or pointer found; may be called indirectly)' % ('  ' * depth, fn))
            level = nxt
            if not level: break
        guarded = [hex(x) for x in seen if x in readers]
        print('functions in the upward chain that read a CRT ISA variable:', guarded or 'NONE')
        # printable strings referenced by the chain (hint at purpose)
        hint = set()
        for a, mn, ops in ins:
            if fn_of(a) in seen:
                m = re.search(r'# 0x([0-9a-f]+)', ops)
                if mn == 'lea' and m:
                    off = r2o(int(m.group(1), 16) - img)
                    if off:
                        s = d[off:off + 60].split(b'\0')[0]
                        if len(s) >= 4 and all(32 <= c < 127 for c in s): hint.add(s.decode())
        print('string constants referenced inside the chain:', sorted(hint)[:12])
        # ANY feature-style test of a global inside the chain (covers non-CRT detection such as BoringSSL's ia32cap):
        gl = collections.defaultdict(set)
        for a, mn, ops in ins:
            if fn_of(a) in seen and mn in ('test', 'cmp', 'bt', 'and') and 'rip+' in ops:
                m = re.search(r'# 0x([0-9a-f]+)', ops)
                if m: gl[int(m.group(1), 16)].add(fn_of(a))
        nread = collections.Counter()
        for a, mn, ops in ins:
            m = re.search(r'# 0x([0-9a-f]+)', ops)
            if m and int(m.group(1), 16) in gl: nread[int(m.group(1), 16)] += 1
        print('globals tested with test/cmp/bt/and inside the chain (addr: #chain fns, #accesses module-wide):',
              {hex(g): (len(f), nread[g]) for g, f in sorted(gl.items())} or 'none')
if __name__ == '__main__':
    main(sys.argv[1], sys.argv[2:])
