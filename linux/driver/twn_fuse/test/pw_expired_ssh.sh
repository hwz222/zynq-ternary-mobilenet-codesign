#!/bin/bash
# What ssh does with the release image's expired default password, before anyone has changed it.
# Run on a Linux host (or WSL) with OpenSSH, sshpass and expect, right after the board has booted
# the release image:
#
#   bash pw_expired_ssh.sh [board address]  > H1_ssh_expired.log
#
# Cases: a command over ssh, scp, a wrong password, and an interactive login (typed by expect) that
# presses Ctrl-C at the first 'New password:'. Nothing changes the password. Host keys are not kept
# (the image generates new ones at every boot).
B=${1:-192.168.10.2}
O="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o PubkeyAuthentication=no -o PreferredAuthentications=password"
x() { echo "# $*"; bash -c "$*" 2>&1; echo "exit $?"; }
echo "== $(date -u '+%Y-%m-%d %H:%M UTC')  from the PC (OpenSSH $(ssh -V 2>&1 | cut -d, -f1 | cut -d_ -f2)) to the board, before any password change"
x "sshpass -p twn-v1.1 ssh $O root@$B 'echo a command ran on the board'"
x "echo test > /tmp/pw_probe.txt; sshpass -p twn-v1.1 scp $O /tmp/pw_probe.txt root@$B:/tmp/"
x "sshpass -p wrong-password ssh $O root@$B 'echo a command ran on the board'"
echo "# ssh -tt root@$B (an interactive login, typed by expect): the default password twice (login, then 'Current password:'), Ctrl-C at 'New password:', then 15 s of output"
expect -c "
  set timeout 20
  spawn ssh -tt $O root@$B
  expect -re {[Pp]assword: *$} { send \"twn-v1.1\r\" }
  expect -re {[Cc]urrent (UNIX )?password: *$} { send \"twn-v1.1\r\" }
  expect -re {[Nn]ew password: *$} { send \"\003\" }
  set timeout 15
  expect {
    -re {.+} { exp_continue }
    eof { puts \"\n(the connection closed)\" }
    timeout { puts \"\n(still open after 15 s, no further output)\" }
  }
" 2>&1 | tr -d '\r'
echo "exit ${PIPESTATUS[0]}"
