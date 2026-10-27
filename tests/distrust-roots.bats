#!/usr/bin/env bats

# Covers distrust-roots.sh against a fake host root. Stubs stand in for mount,
# systemctl and update-ca-certificates. The exit codes are listed in
# distrust-roots.sh and are written as literals here on purpose: they are the
# contract with entrypoint.sh.

EMSIGN=emSign_ECC_Root_CA_-_G3
COMODO=Comodo_AAA_Services_root

setup() {
    load 'test_helper'
}

@test "dry run reports the pending roots and changes nothing" {
    setup_root "${EMSIGN}" "${COMODO}"

    run_host

    assert_failure 4
    assert_output "Still trusted: ${EMSIGN} ${COMODO}"
    assert_store_unchanged
    assert_not_remounted
}

@test "distrusts both roots and restores the read-only mount" {
    setup_root "${EMSIGN}" "${COMODO}"

    run_host DRY_RUN=0

    assert_success
    assert_line "Distrusted: ${EMSIGN} ${COMODO}"
    refute_trusted "${EMSIGN}"
    refute_trusted "${COMODO}"
    assert_trusted ISRG_Root_X1
    run grep -x "!mozilla/${EMSIGN}.crt" "${R}/etc/ca-certificates.conf"
    assert_success
    run cat "${R}/mount.log"
    assert_output "mount -o remount,rw /
mount -o remount,ro /"
}

@test "distrusts emSign alone when Comodo is absent" {
    setup_root "${EMSIGN}"

    run_host DRY_RUN=0

    assert_success
    assert_line "Distrusted: ${EMSIGN}"
    refute_trusted "${EMSIGN}"
}

@test "a second run does nothing and does not remount" {
    setup_root "${EMSIGN}" "${COMODO}"
    run_host DRY_RUN=0
    assert_success
    rm "${R}/mount.log"

    run_host DRY_RUN=0

    assert_failure 3
    assert_output "The roots are already distrusted"
    assert_not_remounted
}

@test "a fixed release without the roots does nothing" {
    setup_root

    run_host DRY_RUN=0

    assert_failure 3
    assert_store_unchanged
    assert_not_remounted
}

@test "a failed rebuild restores the CA store and the read-only mount" {
    setup_root "${EMSIGN}"

    run_host DRY_RUN=0 UCC_FAIL=1

    assert_failure 1
    assert_line --partial "Restoring the CA store"
    assert_store_unchanged
    run tail -n 1 "${R}/mount.log"
    assert_output "mount -o remount,ro /"
}

@test "a rebuild that keeps a distrusted root restores the CA store" {
    setup_root "${EMSIGN}"

    run_host DRY_RUN=0 UCC_IGNORE_BANG=1

    assert_failure 1
    assert_line --partial "${EMSIGN} is still in"
    assert_store_unchanged
}

@test "a rebuild that drops an unrelated root restores the CA store" {
    setup_root "${EMSIGN}"

    run_host DRY_RUN=0 UCC_DROP=Other_Root

    assert_failure 1
    assert_line --partial "The bundle shrank from 3 to 1"
    assert_store_unchanged
}

@test "stops without changes when / cannot be remounted read-write" {
    setup_root "${EMSIGN}"

    run_host DRY_RUN=0 MOUNT_FAIL=1

    assert_failure 5
    assert_line --partial "Unable to remount / read-write"
    refute_line --partial "Restoring"
    assert_store_unchanged
}

@test "refuses a custom CA store when the bind mount is inactive" {
    setup_root "${EMSIGN}"
    install_custom_ca

    run_host DRY_RUN=0 BIND_ACTIVE=3

    assert_failure 1
    assert_line "A custom CA is installed, but bind-etc-ssl-certs.service is not active"
    assert_store_unchanged
    assert_not_remounted
}

@test "distrusts the roots in a custom CA store when the bind mount is active" {
    setup_root "${EMSIGN}"
    install_custom_ca

    run_host DRY_RUN=0

    assert_success
    refute_trusted "${EMSIGN}"
}
