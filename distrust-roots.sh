#!/bin/sh
# Runs on the hostOS as a transient systemd unit, never in the container.
# Removes the roots that chain to the compromised eMudhra intermediates.
# See https://github.com/balena-os/meta-balena/pull/3958
#
# Exit codes:
#   0  distrusted the roots, the host needs a reboot
#   1  failed, the CA store is restored from the backup
#   3  nothing to do
#   4  dry run, the roots are still trusted
#   5  / cannot be remounted read-write, as on balenaOS v7 and later
set -eu

EXIT_PATCHED=0
EXIT_FAILED=1
EXIT_NOOP=3
EXIT_PENDING=4
EXIT_UNSUPPORTED=5

CONF=/etc/ca-certificates.conf
CERTS_DIR=/etc/ssl/certs
BUNDLE="${CERTS_DIR}/ca-certificates.crt"
MOZILLA_DIR=/usr/share/ca-certificates/mozilla
BALENA_CA_DIR=/usr/share/ca-certificates/balena
CRTDIR_BIND_SERVICE=bind-etc-ssl-certs.service
BACKUP_DIR=/run/ca-distrust-backup
# A root that must survive the rebuild
CANARY="${CERTS_DIR}/ISRG_Root_X1.pem"
ROOTS="emSign_ECC_Root_CA_-_G3 Comodo_AAA_Services_root"

fail() {
    echo "$*" >&2
    exit "${EXIT_FAILED}"
}

# A root is pending when the conf selects it or the CA store still has its link
pending=""
for root in ${ROOTS}; do
    if { [ -e "${MOZILLA_DIR}/${root}.crt" ] && grep -qxF "mozilla/${root}.crt" "${CONF}"; } \
        || [ -e "${CERTS_DIR}/${root}.pem" ]; then
        pending="${pending} ${root}"
    fi
done

if [ -z "${pending}" ]; then
    echo "The roots are already distrusted"
    exit "${EXIT_NOOP}"
fi
echo "Still trusted:${pending}"

if [ "${DRY_RUN:-1}" != 0 ]; then
    exit "${EXIT_PENDING}"
fi

# A custom CA moves the CA store to the state partition. Without the bind
# mount, the rebuild writes to the rootfs copy that nothing reads.
if [ -n "$(ls -A "${BALENA_CA_DIR}" 2> /dev/null)" ] && ! systemctl -q is-active "${CRTDIR_BIND_SERVICE}"; then
    fail "A custom CA is installed, but ${CRTDIR_BIND_SERVICE} is not active"
fi

rm -rf "${BACKUP_DIR}"
mkdir -p "${BACKUP_DIR}/certs"
cp -a "${CONF}" "${BACKUP_DIR}/"
cp -a "${CERTS_DIR}/." "${BACKUP_DIR}/certs/"
certs_before=$(grep -c "BEGIN CERTIFICATE" "${BUNDLE}")

remounted=""
# The remount comes before the trap, because a failed remount changes nothing
if grep -q " / [^ ]* ro[, ]" /proc/mounts; then
    if ! mount -o remount,rw /; then
        echo "Unable to remount / read-write. Update balenaOS to a release that distrusts the roots." >&2
        exit "${EXIT_UNSUPPORTED}"
    fi
    remounted=1
fi

# shellcheck disable=SC2329 # invoked by the EXIT trap
cleanup() {
    status=$?
    if [ "${status}" -ne "${EXIT_PATCHED}" ]; then
        echo "Restoring the CA store from ${BACKUP_DIR}" >&2
        cp -a "${BACKUP_DIR}/ca-certificates.conf" "${CONF}"
        rm -rf "${CERTS_DIR:?}"/*
        cp -a "${BACKUP_DIR}/certs/." "${CERTS_DIR}/"
    fi
    sync
    if [ -n "${remounted}" ]; then
        mount -o remount,ro / || echo "Unable to remount / read-only" >&2
    fi
    exit "${status}"
}
trap cleanup EXIT

for root in ${pending}; do
    sed -i "s|^mozilla/${root}\.crt\$|!mozilla/${root}.crt|" "${CONF}"
done
update-ca-certificates --fresh

# The bundle may lose one certificate per distrusted root and no more
certs_min=${certs_before}
for root in ${pending}; do
    [ ! -e "${CERTS_DIR}/${root}.pem" ] || fail "${root} is still in ${CERTS_DIR}"
    certs_min=$((certs_min - 1))
done
[ -e "${CANARY}" ] || fail "The rebuild removed ${CANARY}"
certs_after=$(grep -c "BEGIN CERTIFICATE" "${BUNDLE}")
[ "${certs_after}" -ge "${certs_min}" ] || fail "The bundle shrank from ${certs_before} to ${certs_after} certificates"

echo "Distrusted:${pending}"
exit "${EXIT_PATCHED}"
