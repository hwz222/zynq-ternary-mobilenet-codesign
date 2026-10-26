# Installed only into images built with the published default root password (linux/build_linux.sh
# without BOARD_PW). An interactive root login has to set a new password before it gets a shell.
# The root file system is an initramfs, so the new password lasts until the next reboot.
# Non-interactive ssh commands are not stopped; they still need the password to log in.
if [ -t 0 ] && [ "$(id -u)" = 0 ] && [ ! -e /run/twn-pw-changed ]; then
    echo "This image uses a published default root password. Set a new one now."
    until passwd root; do :; done
    touch /run/twn-pw-changed
fi
