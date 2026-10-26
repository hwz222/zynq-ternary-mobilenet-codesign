# Installed only into images built with the published default root password (linux/build_linux.sh
# without BOARD_PW). An interactive root login has to set a new password before it gets a shell:
# Ctrl-C, Ctrl-\ and Ctrl-Z are ignored until passwd succeeds (passwd inherits the ignored signals).
# The root file system is an initramfs, so the new password lasts until the next reboot, and the
# next boot asks again. Non-interactive ssh commands are not stopped; they still need the password.
if [ -t 0 ] && [ "$(id -u)" = 0 ] && [ ! -e /run/twn-pw-changed ]; then
    echo "This image uses a published default root password. Set a new one now."
    trap '' INT QUIT TSTP
    until passwd root; do :; done
    trap - INT QUIT TSTP
    touch /run/twn-pw-changed
fi
