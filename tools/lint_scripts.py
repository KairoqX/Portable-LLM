#!/usr/bin/env python3
"""Heuristic static checks for .ps1/.bat files (NOT a real parser; no PowerShell available when written).
Checks: ASCII only, CRLF for .bat, balanced (){}[] outside strings/comments, here-strings closed."""
import sys, re, glob, os
root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
bad = 0
def err(f, m):
    global bad; bad += 1; print('FAIL', os.path.relpath(f, root), m)
def strip_ps(t):
    out = []; i = 0; n = len(t)
    stack = []
    while i < n:
        c = t[i]
        if t.startswith("@'", i) and re.match(r"@'[ \t]*\r?\n", t[i:]):
            j = t.find("\n'@", i)
            if j < 0: raise ValueError('unterminated here-string'); 
            i = j + 3; continue
        if c == '#': 
            while i < n and t[i] != '\n': i += 1
            continue
        if c == "'":
            i += 1
            while i < n:
                if t[i] == "'":
                    if i + 1 < n and t[i+1] == "'": i += 2; continue
                    break
                i += 1
            i += 1; continue
        if c == '"':
            i += 1
            while i < n and t[i] != '"':
                if t[i] == '`': i += 1
                i += 1
            i += 1; continue
        out.append(c); i += 1
    return ''.join(out)
for f in sorted(glob.glob(os.path.join(root, '**', '*.ps1'), recursive=True) + glob.glob(os.path.join(root, '*.bat'))):
    if os.sep + 'archive' + os.sep in f: continue
    b = open(f, 'rb').read()
    if any(x > 127 for x in b): err(f, 'non-ASCII byte (PowerShell 5.1 reads BOM-less files as ANSI)')
    t = b.decode('latin1')
    if f.endswith('.bat'):
        if b.count(b'\n') != b.count(b'\r\n'): err(f, 'LF-only line endings in batch file')
        continue
    try: s = strip_ps(t)
    except ValueError as e: err(f, str(e)); continue
    for o, c in ('()', '{}', '[]'):
        if s.count(o) != s.count(c): err(f, 'unbalanced %s%s: %d vs %d' % (o, c, s.count(o), s.count(c)))
print('lint done,', bad, 'problem(s)'); sys.exit(1 if bad else 0)
