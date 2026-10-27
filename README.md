# ca-distrust-block

A balena block that removes two roots from the hostOS CA store:

- `emSign_ECC_Root_CA_-_G3`
- `Comodo_AAA_Services_root`

Both roots chain to the compromised eMudhra intermediates. These meta-balena
releases distrust them:

- v9.0.2 ([#3958](https://github.com/balena-os/meta-balena/pull/3958))
- ESR 2026.10, v7.9.7 ([#3961](https://github.com/balena-os/meta-balena/pull/3961))
- ESR 2026.7, v7.4.2 ([#3960](https://github.com/balena-os/meta-balena/pull/3960))
- ESR 2026.4, v6.11.16 ([#3962](https://github.com/balena-os/meta-balena/pull/3962))

This block applies the same change to devices that cannot update to one of
those releases, for example because of BSP compatibility issues.

> [!WARNING]
> This block has been tested on two devices only. See [Status](#status).

## Supported releases

The block supports balenaOS releases before v7 that do not have the fix. On a
release that already distrusts the roots, the block does nothing.

The block does not work on balenaOS v7 and later. From v7, the root
filesystem has no writable layer and `mount -o remount,rw /` fails (see
[the v7 announcement](https://blog.balena.io/introducing-balenaos-v7-read-only-root-by-design/)).
On such a device, the block logs the failure and stops. Update a v7 or v8
device to one of the fixed releases above.

## How it works

1. The container starts a transient systemd unit, `ca-distrust`, on the host
   over D-Bus.
2. The unit runs `distrust-roots.sh` with the host's own
   `update-ca-certificates`. meta-balena patches that script, so the
   container's Debian copy is not a substitute.
3. The script marks the roots with `!` in `/etc/ca-certificates.conf`,
   remounts `/` read-write, rebuilds `/etc/ssl/certs`, then remounts `/`
   read-only. `/` is the overlay2 mount of the hostapp container, so the
   change lands in that container's writable layer on the active root
   partition. The change persists across reboots.
4. On any failure, the script restores the conf and `/etc/ssl/certs` from a
   backup in `/run`. A broken CA store would cut the device off from the API.

On a device with a custom CA, `/etc/ssl/certs` is a bind mount from the state
partition. The script refuses to run if `bind-etc-ssl-certs.service` is not
active.

The script reads the host state on each run. A second run does nothing.

## Configuration

- `DRY_RUN`, default `1`. `1` reports the pending roots and changes nothing.
  `0` distrusts them.
- `AUTO_REBOOT`, default `0`. `1` reboots through the supervisor after the
  patch. The supervisor honours update locks.

The host needs a reboot after the patch, so that balena-engine and other host
services load the new CA store. `AUTO_REBOOT=1` reboots at most once per
patch.

## Rollout

1. Add the block to the fleet with the defaults. Each device reports in its
   logs whether the roots are still trusted.
2. Set `DRY_RUN=0` on a small canary group of devices.
3. On each canary, run `journalctl -u ca-distrust` on the host and check that
   the unit succeeded. Reboot the device and check that it reconnects.
4. Set `DRY_RUN=0` on the fleet.

A failed run retries with backoff from 60 seconds to one hour.

## Security

The `io.balena.features.dbus` label gives the container root on the host.
Build the block from source with `build: .` and review `distrust-roots.sh`
first. Do not pull a prebuilt image.

## Limits

- **Host updates.** A host update to a fixed release keeps the roots
  distrusted. A host update to an unfixed release replaces the rootfs and
  trusts the roots again. The block runs again on boot and reapplies the patch.
- **armv6 devices** (Raspberry Pi 1 and Zero) cannot build the block. The
  Debian base image does not publish a variant that armv6 runs. Update those
  devices to a fixed release.
- **The supervisor** uses the CA bundle built into Node.js, not the host
  store. The block does not change it.
- **User containers** use their own CA bundles. The block does not change
  them.

## Status

Tested:

- raspberrypi3-64, balenaOS 6.10.24+rev2: dry run, patch, manual reboot, and
  a second run that does nothing.
- raspberrypi4-64, balenaOS 6.12.3+rev4: patch with `AUTO_REBOOT=1`. The
  supervisor rebooted the device once.

On both devices, the patch removed both roots, persisted across the reboot,
and the device reconnected.

Not tested:

- Releases before 6.10.
- Old BSP kernels and secure boot images. `mount -o remount,rw /` may fail on
  them.
- A device with a custom CA.

## Tests

The bats suite runs `distrust-roots.sh` against a fake root with stub
`mount`, `systemctl` and `update-ca-certificates`.

```sh
git submodule update --init
./tests/bats/bin/bats tests/
HOST_SH=dash ./tests/bats/bin/bats tests/
```