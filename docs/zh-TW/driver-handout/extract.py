"""Copy whole C functions out of the repository's source files into build/snippets/, so the handout
always shows the code as it is, with its real line numbers.

    python extract.py                 # every snippet listed in snippets.txt

snippets.txt has one line per snippet:  <repo-relative file>  <function name>
A function is taken from the line that starts its definition (the name followed by "(" at the start
of a line, or after the return type) down to the first "}" in column 0.
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.normpath(os.path.join(HERE, '..', '..', '..'))
OUT = os.path.join(HERE, 'build', 'snippets')


def extract(path, func):
    lines = open(os.path.join(REPO, path), encoding='utf-8').read().splitlines()
    head = re.compile(r'^[A-Za-z_].*\b' + re.escape(func) + r'\s*\(')
    for i, line in enumerate(lines):
        if head.match(line) and not line.rstrip().endswith(';'):
            for j in range(i, len(lines)):
                if lines[j].startswith('}'):
                    return i + 1, lines[i:j + 1]
    sys.exit('extract.py: %s not found in %s' % (func, path))


def main():
    os.makedirs(OUT, exist_ok=True)
    for raw in open(os.path.join(HERE, 'snippets.txt'), encoding='utf-8'):
        raw = raw.split('#', 1)[0].strip()
        if not raw:
            continue
        path, func = raw.split()
        first, body = extract(path, func)
        name = os.path.basename(path).replace('.', '_') + '__' + func
        with open(os.path.join(OUT, name + '.c'), 'w', encoding='utf-8', newline='\n') as f:
            f.write('\n'.join(body) + '\n')
        # \snip{file}{func} in handout.tex reads this to number the lines and title the box
        with open(os.path.join(OUT, name + '.tex'), 'w', encoding='utf-8', newline='\n') as f:
            f.write('\\def\\snipfirst{%d}\\def\\snippath{%s}\n' % (first, path.replace('_', '\\_')))
        print('%-40s %-28s line %d, %d lines' % (path, func, first, len(body)))


if __name__ == '__main__':
    main()
