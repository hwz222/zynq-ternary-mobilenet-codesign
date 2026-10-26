SUMMARY = "Static 192.168.10.2/24 on eth0 for the direct PC-to-board link (board/deploy.sh); first-login password change"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = "file://board-static-ip.service \
           file://twn-firstlogin.sh \
          "

inherit systemd

SYSTEMD_SERVICE:${PN} = "board-static-ip.service"
SYSTEMD_AUTO_ENABLE = "enable"

# "1" in images built with the published default password (linux/build_linux.sh sets it)
TWN_FORCE_PW_CHANGE ?= "0"

do_install() {
    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${WORKDIR}/board-static-ip.service ${D}${systemd_system_unitdir}/
    if [ "${TWN_FORCE_PW_CHANGE}" = "1" ]; then
        install -d ${D}${sysconfdir}/profile.d
        install -m 0644 ${WORKDIR}/twn-firstlogin.sh ${D}${sysconfdir}/profile.d/
    fi
}
