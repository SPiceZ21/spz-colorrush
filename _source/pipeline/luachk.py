import re, sys

def strip(src):
    """Blank out comments and string literals so keyword scanning is safe."""
    out, i, n = [], 0, len(src)
    while i < n:
        if src.startswith('--', i):
            m = re.match(r'--\[(=*)\[', src[i:])
            if m:
                close = ']' + m.group(1) + ']'
                j = src.find(close, i)
                seg = src[i:(n if j < 0 else j + len(close))]
                out.append('\n' * seg.count('\n'))
                i = n if j < 0 else j + len(close)
            else:
                j = src.find('\n', i)
                i = n if j < 0 else j
            continue
        c = src[i]
        if c in '"\'':
            q, i = c, i + 1
            while i < n:
                if src[i] == '\\':
                    i += 2; continue
                if src[i] == q:
                    i += 1; break
                i += 1
            out.append('""')
            continue
        m = re.match(r'\[(=*)\[', src[i:])
        if m:
            close = ']' + m.group(1) + ']'
            j = src.find(close, i)
            seg = src[i:(n if j < 0 else j + len(close))]
            out.append('""' + '\n' * seg.count('\n'))
            i = n if j < 0 else j + len(close)
            continue
        out.append(c); i += 1
    return ''.join(out)


def check(path):
    src = strip(open(path, encoding='utf-8').read())
    stack, errs, line = [], [], 1
    for m in re.finditer(r'\n|\b[A-Za-z_]\w*\b', src):
        t = m.group(0)
        if t == '\n':
            line += 1
            continue
        if t in ('function', 'if'):
            stack.append((t, line))
        elif t in ('for', 'while'):
            stack.append((t, line))
        elif t == 'do':
            # `do` closing a for/while header is not its own block
            if not (stack and stack[-1][0] in ('for', 'while')):
                stack.append(('do', line))
        elif t == 'repeat':
            stack.append(('repeat', line))
        elif t == 'until':
            if stack and stack[-1][0] == 'repeat':
                stack.pop()
            else:
                errs.append('line %d: "until" without "repeat"' % line)
        elif t == 'end':
            if not stack:
                errs.append('line %d: stray "end"' % line)
            else:
                stack.pop()
    for kind, ln in stack:
        errs.append('unclosed "%s" opened at line %d' % (kind, ln))
    for o, c in ('()', '{}', '[]'):
        a, b = src.count(o), src.count(c)
        if a != b:
            errs.append('bracket imbalance %s%s: %d open vs %d close' % (o, c, a, b))
    print(('FAIL ' if errs else 'OK   ') + path)
    for e in errs:
        print('   ' + e)
    return not errs


ok = all(check(p) for p in sys.argv[1:])
sys.exit(0 if ok else 1)
