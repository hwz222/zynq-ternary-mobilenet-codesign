SUMMARY = "Static 192.168.10.2/24 on eth0 for the direct PC-to-board link (board/deploy.sh)"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = "file://board-static-ip.service"

inherit systemd

SYSTEMD_SERVICE:${PN} = "board-static-ip.service"
SYSTEMD_AUTO_ENABLE = "enable"

do_install() {
    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${WORKDIR}/board-static-ip.service ${D}${systemd_system_unitdir}/
}
