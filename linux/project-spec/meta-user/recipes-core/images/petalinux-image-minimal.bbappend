# board/deploy.sh logs in as root with a password; the stock sshd_config keeps both off.
# (Done on the image, not as an openssh bbappend: that would rebuild openssh from source.)
ROOTFS_POSTPROCESS_COMMAND:append = " ternpose_sshd_root_login;"
ternpose_sshd_root_login() {
    sed -i -e 's/^#PermitRootLogin .*/PermitRootLogin yes/' \
           -e 's/^#PasswordAuthentication yes/PasswordAuthentication yes/' \
           ${IMAGE_ROOTFS}${sysconfdir}/ssh/sshd_config
}
