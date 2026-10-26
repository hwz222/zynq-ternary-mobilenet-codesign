"""The first login on the board's serial console, with the release image's expired default password.

    python first_login_serial.py <port> <new password> <out.log>      (needs pyserial)

Run right after the release image has booted, before anyone has logged in. In order: Ctrl-C at the
first 'New password:' prompt, an empty new password, two different passwords, then the real change;
then root's password-aging field is shown and the shell logged out. <out.log> gets the console
transcript with control characters removed; its second line lists every key sequence sent (the
board echoes no password), its last line how the script read each prompt.
"""
import re
import sys
import time

import serial

PORT, NEWPW, OUT = sys.argv[1], sys.argv[2], sys.argv[3]
ser = serial.Serial(PORT, 115200, timeout=0.2)
raw = bytearray()
keys = []

P_LOGIN = rb'login: *$'
P_PASS = rb'\nPassword: *$'
P_CUR = rb'[Cc]urrent (UNIX )?password: *$'
P_NEW = rb'[Nn]ew password: *$'
P_RETYPE = rb'[Rr]etype new password: *$'
P_SHELL = rb'root@[^\r\n]*# *$'


def until(pats, t=30):
    buf = b''
    t0 = time.time()
    while time.time() - t0 < t:
        b = ser.read(4096)
        if b:
            buf += b
            raw.extend(b)
            for name, p in pats:
                if re.search(p, buf[-200:]):
                    return name
    return 'timeout'


def send(s, note):
    ser.write(s.encode() + b'\r')
    keys.append(note)


def to_new_prompt(state):
    """From the login prompt to the first 'New password:' prompt."""
    if state != 'login':
        send('', 'Enter')
        state = until([('login', P_LOGIN), ('shell', P_SHELL)], 20)
        if state != 'login':
            return state
    send('root', 'root')
    if until([('pass', P_PASS)], 20) != 'pass':
        return 'no password prompt'
    send('twn-v1.1', 'the default password')
    s = until([('cur', P_CUR), ('new', P_NEW), ('shell', P_SHELL), ('login', P_LOGIN)], 30)
    if s == 'cur':
        send('twn-v1.1', 'the default password (current password)')
        s = until([('new', P_NEW), ('shell', P_SHELL), ('login', P_LOGIN)], 30)
    return s


date = time.strftime('%Y-%m-%d %H:%M UTC', time.gmtime())
result = []
state = to_new_prompt('start')
result.append('first login reached: ' + state)
if state == 'new':
    ser.write(b'\x03')
    keys.append('Ctrl-C')
    state = until([('login', P_LOGIN), ('new', P_NEW), ('shell', P_SHELL), ('retype', P_RETYPE)], 20)
    result.append('after Ctrl-C: ' + state)
if state == 'login':
    state = to_new_prompt('login')
    result.append('second login reached: ' + state)
if state == 'new':
    send('', 'Enter (an empty new password)')
    state = until([('retype', P_RETYPE), ('new', P_NEW), ('login', P_LOGIN), ('shell', P_SHELL)], 20)
    result.append('after an empty password: ' + state)
    if state == 'retype':
        send('', 'Enter (the empty password again)')
        state = until([('new', P_NEW), ('login', P_LOGIN), ('shell', P_SHELL)], 20)
        result.append('after the empty password twice: ' + state)
if state == 'login':
    state = to_new_prompt('login')
    result.append('third login reached: ' + state)
if state == 'new':
    send(NEWPW, 'the new password')
    if until([('retype', P_RETYPE)], 20) == 'retype':
        send(NEWPW + 'x', 'a different password')
        state = until([('new', P_NEW), ('login', P_LOGIN), ('shell', P_SHELL)], 20)
        result.append('after two different passwords: ' + state)
if state == 'login':
    state = to_new_prompt('login')
    result.append('fourth login reached: ' + state)
if state == 'new':
    send(NEWPW, 'the new password')
    if until([('retype', P_RETYPE)], 20) == 'retype':
        send(NEWPW, 'the new password again')
        state = until([('shell', P_SHELL), ('new', P_NEW), ('login', P_LOGIN)], 30)
        result.append('after the new password twice: ' + state)
if state == 'shell':
    send("cut -d: -f1,3 /etc/shadow | grep -E '^(root|petalinux):'", 'a command')
    until([('shell', P_SHELL)], 20)
    send('exit', 'exit')
    until([('login', P_LOGIN)], 20)

# the transcript without terminal control sequences
s = raw.decode('utf-8', 'replace')
s = re.sub(r'\x1b\[[0-9;?]*[A-Za-z]', '', s)
s = re.sub(r'\x1b[()][0-9A-Za-z]', '', s)
s = re.sub(r'\x1b[78=>]', '', s).replace('\r', '')
s = ''.join(c for c in s if c == '\n' or c >= ' ')
body = s.split('\n')
while body and not body[0].strip():
    body.pop(0)
while body and not body[-1].strip():
    body.pop()
out = ['== %s  serial console (%s, 115200) of the board; control characters removed' % (date, PORT),
       '# keys typed, in order (the board echoes no password): ' + '; '.join(keys)]
out += body
out.append('# prompts as the script read them: ' + ' | '.join(result))
open(OUT, 'w', newline='\n').write('\n'.join(out) + '\n')
print('\n'.join(result))
