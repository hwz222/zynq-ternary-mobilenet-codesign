"""Copy pieces of the repository's source files into build/snippets/, so the handout always shows
the code as it is, with its real line numbers.

    python extract.py                 # every snippet listed in snippets.txt

snippets.txt has one line per snippet:   <repo-relative file> | <selector> | <label>
  fn:NAME   a function, struct, array or #define named NAME: from the line that defines it down to
            the first "}" in column 0 (for a #define: down to the first line without a trailing "\")
  at:TEXT   from the first line that contains TEXT down to the line before the next blank line
The file may be written git:<commit>:<path> to quote it as it was in that commit (the v1.0.0 code).
The label names the output (build/snippets/<label>.c/.tex); \\snip{<label>} in handout.tex prints it.
"""
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.normpath(os.path.join(HERE, '..', '..', '..'))
OUT = os.path.join(HERE, 'build', 'snippets')


def read(path):
    if path.startswith('git:'):
        _, rev, rel = path.split(':', 2)
        out = subprocess.run(['git', '-C', REPO, 'show', '%s:%s' % (rev, rel)],
                             capture_output=True, check=True).stdout
        return out.decode('utf-8').splitlines()
    return open(os.path.join(REPO, path), encoding='utf-8').read().splitlines()


def shown(path):
    """the path printed above the box; for git:<commit>:<path>, also the commit"""
    if path.startswith('git:'):
        _, rev, rel = path.split(':', 2)
        return '%s @ v1.0.0 (%s)' % (rel, rev)
    return path


def find(path, sel):
    lines = read(path)
    kind, arg = sel.split(':', 1)
    if kind == 'fn':
        head = re.compile(r'^(#define\s+%s\b|[A-Za-z_].*\b%s\b\s*[(\[={])' % (re.escape(arg), re.escape(arg)))
        for i, line in enumerate(lines):
            if head.match(line) and not line.rstrip().endswith(';'):
                if line.startswith('#define'):
                    j = i
                    while lines[j].rstrip().endswith('\\'):
                        j += 1
                    return i + 1, lines[i:j + 1]
                for j in range(i, len(lines)):
                    if lines[j].startswith('}'):
                        return i + 1, lines[i:j + 1]
    elif kind == 'at':
        for i, line in enumerate(lines):
            if arg in line:
                j = i
                while j + 1 < len(lines) and lines[j + 1].strip():
                    j += 1
                return i + 1, lines[i:j + 1]
    sys.exit('extract.py: %s not found in %s' % (sel, path))


def main():
    os.makedirs(OUT, exist_ok=True)
    seen = set()
    for raw in open(os.path.join(HERE, 'snippets.txt'), encoding='utf-8'):
        if not raw.strip() or raw.lstrip().startswith('#'):
            continue
        path, sel, label = [x.strip() for x in raw.split('|')]
        if label in seen:
            sys.exit('extract.py: label %s used twice' % label)
        seen.add(label)
        first, body = find(path, sel)
        with open(os.path.join(OUT, label + '.c'), 'w', encoding='utf-8', newline='\n') as f:
            f.write('\n'.join(body) + '\n')
        # \snip{label} in handout.tex reads this to number the lines and title the box
        with open(os.path.join(OUT, label + '.tex'), 'w', encoding='utf-8', newline='\n') as f:
            f.write('\\def\\snipfirst{%d}\\def\\sniplast{%d}\\def\\snippath{%s}\n'
                    % (first, first + len(body) - 1, shown(path).replace('_', '\\_')))
        print('%-44s %-34s %s line %d, %d lines' % (path, sel, label, first, len(body)))


if __name__ == '__main__':
    main()
