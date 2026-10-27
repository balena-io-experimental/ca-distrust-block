#!/bin/bash

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "${TESTS_DIR}")"
STUBS_DIR="${TESTS_DIR}/stubs"

load "${TESTS_DIR}/test_helper/bats-support/load"
load "${TESTS_DIR}/test_helper/bats-assert/load"

# The stubs shadow only mount, systemctl and update-ca-certificates
PATH="${STUBS_DIR}:${PATH}"

#######################################
# Build a fake host root that trusts ISRG_Root_X1, Other_Root and the given
# roots. Write a copy of distrust-roots.sh that reads the fake root.
# Globals:
#   R: set to the fake root and exported for the stubs
#   STORE_ORIG: set to the snapshot of the CA store
# Arguments:
#   roots: extra Mozilla roots to install and trust
#######################################
setup_root() {
    R="${BATS_TEST_TMPDIR}/root"
    export R

    mkdir -p "${R}/etc/ssl/certs" "${R}/usr/share/ca-certificates/mozilla" \
        "${R}/usr/share/ca-certificates/balena" "${R}/proc" "${R}/run"
    echo "/dev/root / ext4 ro,relatime 0 0" > "${R}/proc/mounts"
    : > "${R}/etc/ca-certificates.conf"

    local root
    for root in ISRG_Root_X1 Other_Root "$@"; do
        printf -- '-----BEGIN CERTIFICATE-----\n%s\n' "${root}" \
            > "${R}/usr/share/ca-certificates/mozilla/${root}.crt"
        echo "mozilla/${root}.crt" >> "${R}/etc/ca-certificates.conf"
    done
    update-ca-certificates

    # shellcheck disable=SC2016 # $R expands when host.sh runs
    sed -e 's|=/etc|=$R/etc|; s|=/usr|=$R/usr|; s|=/run|=$R/run|' \
        -e 's|/proc/mounts|$R/proc/mounts|' \
        "${REPO_ROOT}/distrust-roots.sh" > "${BATS_TEST_TMPDIR}/host.sh"

    STORE_ORIG=$(snapshot_store)
}

#######################################
# Print the conf and the CA store listing of the fake root.
#######################################
snapshot_store() {
    cat "${R}/etc/ca-certificates.conf"
    ls -A "${R}/etc/ssl/certs"
}

#######################################
# Run distrust-roots.sh against the fake root.
# HOST_SH selects the shell, sh by default.
# Arguments:
#   assignments: NAME=value pairs for the environment of the script
#######################################
run_host() {
    run env "$@" "${HOST_SH:-sh}" "${BATS_TEST_TMPDIR}/host.sh"
}

install_custom_ca() {
    touch "${R}/usr/share/ca-certificates/balena/balenaRootCA.crt"
}

assert_trusted() {
    assert [ -e "${R}/etc/ssl/certs/$1.pem" ]
}

refute_trusted() {
    refute [ -e "${R}/etc/ssl/certs/$1.pem" ]
}

assert_store_unchanged() {
    assert_equal "$(snapshot_store)" "${STORE_ORIG}"
}

assert_not_remounted() {
    refute [ -e "${R}/mount.log" ]
}
