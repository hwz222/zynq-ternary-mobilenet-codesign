"""Partial check of the device-tree binding wjhuang,twn-fuse.yaml, for machines without dtschema.

    python3 binding_check.py <kernel-source> [system.dtb]   (run in WSL / Linux; needs PyYAML, cpp, dtc)

The official check is `make dt_binding_check DT_SCHEMA_FILES=...` in a kernel tree, which needs the
dtschema package. This script checks what it can without it:
  1. the YAML parses and has the keys every binding needs;
  2. the compatible strings equal the driver's of_match_table (twn_fuse.c);
  3. the example, run through the C preprocessor with the kernel's dt-bindings headers,
     compiles with dtc inside a minimal tree;
  4. the example satisfies the binding's own rules: required properties, and for version 1.1
     an interrupt;
  5. with a .dtb given: its accelerator node (as PetaLinux generated it) has only described
     properties, the required ones, and for version 1.1 an interrupt.
Prints BINDING CHECK: PASS or FAIL.
"""
import os
import re
import subprocess
import sys
import tempfile

import yaml

HERE = os.path.dirname(os.path.abspath(__file__))
BINDING = os.path.join(HERE, '..', 'wjhuang,twn-fuse.yaml')
DRIVER = os.path.join(HERE, '..', 'twn_fuse.c')
fails = []


def check(ok, what):
    print('%-4s %s' % ('PASS' if ok else 'FAIL', what))
    if not ok:
        fails.append(what)


def check_dtb(doc, dtb):
    """5. the accelerator node of a real device tree (the one PetaLinux generated) against the binding"""
    dts = subprocess.run(['dtc', '-q', '-I', 'dtb', '-O', 'dts', dtb], capture_output=True, text=True).stdout
    nodes = [n for n in re.finditer(r'\n(\t+)([\w-]+@[0-9a-f]+) \{\n((?:\1\t.*\n)*?)\1\};', dts)
             if 'wjhuang,twn-fuse' in n.group(3)]
    check(len(nodes) == 1, '%s: one node with a wjhuang,twn-fuse compatible' % os.path.basename(dtb))
    if not nodes:
        return
    body = nodes[0].group(3)
    print('     node %s:' % nodes[0].group(2))
    print(''.join('       ' + line.strip() + '\n' for line in body.splitlines()), end='')
    props = set(re.findall(r'^\s*([a-z#][a-z0-9,#-]*)\s*[=;]', body, re.M))
    generic = {'status', 'phandle', 'interrupt-parent'}   # allowed on every node by the core schemas
    for p in sorted(props - generic):
        check(p in doc['properties'], 'dtb node: property %s is described' % p)
    for r in doc['required']:
        check(r in props, 'dtb node: has required property %s' % r)
    if 'wjhuang,twn-fuse-1.1' in body:
        check('interrupts' in props, 'dtb node: version 1.1 has an interrupt')


def main():
    ksrc = sys.argv[1]
    doc = yaml.safe_load(open(BINDING, encoding='utf-8'))
    for key in ('$id', '$schema', 'title', 'maintainers', 'properties', 'required', 'examples'):
        check(key in doc, 'binding has %s' % key)
    check(os.path.basename(BINDING)[:-5] in doc['$id'], '$id names the file')

    comp = set(doc['properties']['compatible']['enum'])
    drv = set(re.findall(r'\.compatible\s*=\s*"([^"]+)"', open(DRIVER, encoding='utf-8').read()))
    check(comp == drv, 'compatible strings %s equal the driver\'s %s' % (sorted(comp), sorted(drv)))

    for i, ex in enumerate(doc['examples']):
        with tempfile.TemporaryDirectory() as tmp:
            src = os.path.join(tmp, 'ex.dts')
            with open(src, 'w') as f:
                f.write('/dts-v1/;\n' + ex.replace('/ {', '') + '\n/ { #address-cells = <1>; #size-cells = <1>;\n'
                        '  pl_clk0: clock { compatible = "fixed-clock"; #clock-cells = <0>; clock-frequency = <240000000>; };\n'
                        '  gic: interrupt-controller { interrupt-controller; #interrupt-cells = <3>; #address-cells = <0>; };\n'
                        '  bus { compatible = "simple-bus"; #address-cells = <1>; #size-cells = <1>; ranges;\n'
                        '        interrupt-parent = <&gic>;\n')
            # move the example node inside the bus: everything after the #includes
            text = open(src).read()
            node = re.search(r'(accelerator@[0-9a-f]+\s*\{.*?\};)', text, re.S).group(1)
            text = text.replace(node, '') + node + '\n  };\n};\n'
            open(src, 'w').write(text)
            pre = subprocess.run(['cpp', '-nostdinc', '-undef', '-x', 'assembler-with-cpp',
                                  '-I', os.path.join(ksrc, 'include'), src], capture_output=True, text=True)
            check(pre.returncode == 0, 'example %d: preprocesses with the kernel dt-bindings headers' % i)
            dtc = subprocess.run(['dtc', '-I', 'dts', '-O', 'dtb', '-o', os.devnull, '-'], input=pre.stdout,
                                 capture_output=True, text=True)
            check(dtc.returncode == 0, 'example %d: compiles with dtc %s' % (i, dtc.stderr.strip()[:200]))
            props = set(re.findall(r'^\s*([a-z#][a-z0-9,#-]*)\s*=', node, re.M))
            for r in doc['required']:
                check(r in props, 'example %d: has required property %s' % (i, r))
            if '"wjhuang,twn-fuse-1.1"' in node:
                check('interrupts' in props, 'example %d: version 1.1 has an interrupt' % i)
            for p in props:
                check(p in doc['properties'], 'example %d: property %s is described' % (i, p))

    if len(sys.argv) > 2:
        check_dtb(doc, sys.argv[2])
    print('BINDING CHECK: %s' % ('PASS' if not fails else 'FAIL (%d)' % len(fails)))
    return 1 if fails else 0


if __name__ == '__main__':
    sys.exit(main())
