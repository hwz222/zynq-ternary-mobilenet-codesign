#!/bin/bash
# What ssh does with the release image's expired default password, before anyone has changed it.
# Run on a Linux host (or WSL) with OpenSSH, sshpass and expect, right after the board has booted
# the release image:
#
#   bash pw_expired_ssh.sh [board address [new password]]  > H1_ssh_expired.log
#
# Cases: a command over ssh, scp, a wrong password, and an interactive login (typed by expect) that
# presses Ctrl-C at the first 'New password:'. Nothing changes the password, unless a new password
# is given: then a last interactive ssh login sets it, and a command over ssh with it must run.
# expect is a tool that types into an interactive program by script. Host keys are not kept (the
# image generates new ones at every boot).
B=${1:-192.168.10.2}
NEWPW=${2:-}
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
[ -n "$NEWPW" ] || exit 0
echo "# ssh -tt root@$B (typed by expect): the default password twice, then a new password twice (not echoed)"
expect -c "
  set timeout 30
  spawn ssh -tt $O root@$B
  expect -re {[Pp]assword: *$} { send \"twn-v1.1\r\" }
  expect -re {[Cc]urrent (UNIX )?password: *$} { send \"twn-v1.1\r\" }
  expect -re {[Nn]ew password: *$} { send \"$NEWPW\r\" }
  expect -re {[Rr]etype new password: *$} { send \"$NEWPW\r\" }
  expect {
    -re {root@[^\r\n]*# *$} { send \"exit\r\"; puts \"\n(a shell after the change)\"; exp_continue }
    eof { puts \"\n(the connection closed)\" }
    timeout { puts \"\n(no shell and no close after 30 s)\" }
  }
" 2>&1 | tr -d '\r'
echo "exit ${PIPESTATUS[0]}"
x "sshpass -p '$NEWPW' ssh $O root@$B 'echo a command ran on the board; cut -d: -f1,3 /etc/shadow | grep ^root:'" | sed "s/$NEWPW/<new password>/g"
