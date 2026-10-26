#!/usr/bin/env python3
"""codeprint.py -- prove that an edit touched only comments, docstrings and whitespace.

  python tools/codeprint.py check --base DIR FILE...   compare each FILE with DIR/FILE
  python tools/codeprint.py selftest

The "code print" of a file is its token stream with comments and whitespace removed:
  .v .vh .sv .c .h .cpp   C-style tokens; strings, `directives and synthesis pragma comments are kept
  .py                     the AST with docstrings removed
  .tcl .sh .ps1 .cmd .bat every line that is not blank and not a full-line comment, whitespace-normalised
check exits 1 when any file differs and prints the first difference.
"""
import ast
import os
import sys

PRAGMA_WORDS = ('synthesis', 'synopsys', 'pragma', 'translate', 'xilinx', 'cadence')
DIRECTIVES = ('translate_off', 'translate_on', 'attribute', 'keep', 'full_case', 'parallel_case', 'syn_keep',
              'async_set_reset', 'sync_set_reset', 'map_to_module', 'ram_block', 'rom_block', 'resource', 'enum',
              'dc_script_begin', 'dc_script_end', 'fsm', 'state_vector', 'one_hot', 'preserve', 'black_box',
              'implementation')
OPS3 = ('<<<', '>>>', '===', '!==', '<->', '(*)', '<<=', '>>=', '...')
OPS2 = ('<=', '>=', '==', '!=', '&&', '||', '<<', '>>', '**', '~&', '~|', '~^', '^~', '+:', '-:', '->', '(*', '*)',
        '::', '=>', '*>', '++', '--', '+=', '-=', '*=', '/=', '|=', '&=', '^=', '%=')


def is_pragma(body):
    w = body.lower().split()
    if not w:
        return False
    if w[0] in ('translate_off', 'translate_on'):
        return True
    return w[0] in PRAGMA_WORDS and len(w) > 1 and w[1].rstrip(':') in DIRECTIVES


def c_tokens(text):
    out, i, n = [], 0, len(text)
    while i < n:
        c = text[i]
        if c in ' \t\r\n\f':
            i += 1
        elif text.startswith('//', i):
            j = text.find('\n', i)
            j = n if j < 0 else j
            if is_pragma(text[i + 2:j].strip()):
                out.append('PRAGMA:' + ' '.join(text[i + 2:j].split()))
            i = j
        elif text.startswith('/*', i):
            j = text.find('*/', i + 2)
            j = n if j < 0 else j + 2
            if is_pragma(text[i + 2:j - 2].strip()):
                out.append('PRAGMA:' + ' '.join(text[i + 2:j - 2].split()))
            i = j
        elif c == '"':
            j = i + 1
            while j < n and text[j] != '"':
                j += 2 if text[j] == '\\' else 1
            out.append(text[i:j + 1])
            i = j + 1
        elif c == '`':
            j = i + 1
            while j < n and (text[j].isalnum() or text[j] == '_'):
                j += 1
            out.append(text[i:j])
            i = j
        elif c.isalnum() or c in '_$\'':
            j = i
            while j < n and (text[j].isalnum() or text[j] in "_$'"):
                j += 1
            out.append(text[i:j])
            i = j
        else:
            for k in (3, 2):
                if text[i:i + k] in (OPS3 if k == 3 else OPS2):
                    out.append(text[i:i + k])
                    i += k
                    break
            else:
                out.append(c)
                i += 1
    return out


def py_tokens(text):
    tree = ast.parse(text)
    for node in ast.walk(tree):
        if isinstance(node, (ast.Module, ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
            b = node.body
            if b and isinstance(b[0], ast.Expr) and isinstance(getattr(b[0], 'value', None), ast.Constant) \
                    and isinstance(b[0].value.value, str):
                node.body = b[1:] or [ast.Pass()]
    return ast.dump(tree, include_attributes=False).split(', ')


COMMENT_PREFIX = {'.tcl': ('#',), '.sh': ('#',), '.ps1': ('#',), '.xdc': ('#',), '.mk': ('#',), '.txt': ('#',), '.cmd': ('REM ', 'rem ', '::', 'REM\t'),
                  '.bat': ('REM ', 'rem ', '::')}


def line_tokens(text, ext):
    pre = COMMENT_PREFIX[ext]
    out = []
    for n, l in enumerate(text.replace('\r\n', '\n').split('\n')):
        t = l.strip()
        if not t:
            continue
        if t.startswith(pre) and not (n == 0 and t.startswith('#!')):
            continue
        if t.upper() == 'REM':
            continue
        out.append(' '.join(t.split()))
    return out


def tokens(path, text):
    ext = os.path.splitext(path)[1].lower()
    if ext in ('.v', '.vh', '.sv', '.c', '.h', '.cpp', '.hpp'):
        return c_tokens(text)
    if ext == '.py':
        return py_tokens(text)
    if ext in COMMENT_PREFIX:
        return line_tokens(text, ext)
    raise SystemExit('codeprint: no rule for %s' % path)


def read(p):
    return open(p, encoding='utf-8', errors='replace').read()


def check(base, files):
    bad = 0
    for f in files:
        a, b = tokens(f, read(os.path.join(base, f))), tokens(f, read(f))
        if a == b:
            print('OK    %-44s %6d' % (f, len(a)))
            continue
        bad += 1
        k = next((i for i in range(min(len(a), len(b))) if a[i] != b[i]), min(len(a), len(b)))
        print('DIFF  %-44s %d before, %d after; first difference at item %d' % (f, len(a), len(b), k))
        print('      before: ... %s' % ' | '.join(a[max(0, k - 3):k + 3])[:300])
        print('      after : ... %s' % ' | '.join(b[max(0, k - 3):k + 3])[:300])
    return 1 if bad else 0


def selftest():
    cases = [
        ('a.v', 'module m; // c\n assign b=a; /* c */ endmodule', 'module m;\nassign b = a;\nendmodule', True),
        ('a.v', 'x // synthesis translate_off\ny', 'x\ny', False),
        ('a.v', 'x // synthesis logs show\ny', 'x\ny', True),
        ('a.c', 'int a = 1; // one', 'int a = 2; // one', False),
        ('a.py', 'def f():\n    """doc"""\n    return 1\n', 'def f():\n    """other doc, longer"""\n    return 1\n', True),
        ('a.py', 'def f():\n    # c\n    return 1\n', 'def f():\n    return 2\n', False),
        ('a.sh', 'echo a # x\n# c\necho b\n', 'echo a # x\necho b\n', True),
        ('a.sh', 'echo a\n', 'echo b\n', False),
        ('a.cmd', 'REM c\necho a\n', 'echo a\n', True),
    ]
    bad = 0
    for name, x, y, same in cases:
        ok = (tokens(name, x) == tokens(name, y)) == same
        bad += not ok
        print('%s  %s %r' % ('ok  ' if ok else 'FAIL', name, x[:28]))
    return 1 if bad else 0


if __name__ == '__main__':
    a = sys.argv[1:]
    if a[:1] == ['selftest']:
        sys.exit(selftest())
    if a[:1] == ['check'] and '--base' in a:
        i = a.index('--base')
        sys.exit(check(a[i + 1], [x for j, x in enumerate(a[1:], 1) if j not in (i, i + 1)]))
    raise SystemExit(__doc__)
