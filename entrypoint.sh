#!/usr/bin/env bash
set -euo pipefail

readonly EXIT_PATCHED=0
readonly EXIT_NOOP=3
readonly EXIT_PENDING=4
readonly EXIT_UNSUPPORTED=5
readonly UNIT=ca-distrust
readonly HOST_SCRIPT=/usr/src/app/distrust-roots.sh
readonly REBOOT_MARKER=/data/rebooted
readonly BACKOFF_MIN=60
readonly BACKOFF_MAX=3600

export DBUS_SYSTEM_BUS_ADDRESS=unix:path=/host/run/dbus/system_bus_socket
# systemd-run refuses to connect unless this directory marks a systemd host
mkdir -p /run/systemd/system

# Run the script on the host as a transient unit, so it uses the host's
# update-ca-certificates and survives a container stop. The fixed unit name
# stops two runs from overlapping. Base64 keeps systemd from expanding the
# script's $ and % characters. Type=oneshot would fail the start job on any
# non-zero exit, and systemd-run --wait would then return 1, not the exit code.
# shellcheck disable=SC2016 # the host shell expands $SCRIPT
run_on_host() {
	systemd-run --unit="${UNIT}" --wait --collect --quiet \
		--property=Type=exec \
		--setenv=DRY_RUN="${DRY_RUN:-1}" \
		--setenv=SCRIPT="$(base64 -w0 "${HOST_SCRIPT}")" \
		/bin/sh -c 'echo "$SCRIPT" | base64 -d | /bin/sh'
}

reboot_host() {
	if [[ "${AUTO_REBOOT:-0}" != 1 ]]; then
		echo "Reboot the device, so that balena-engine loads the new CA store"
		return
	fi
	# A second patch after a reboot means the rootfs write did not persist
	if [[ -e "${REBOOT_MARKER}" ]]; then
		echo "The device already rebooted once for this patch, not rebooting again" >&2
		return
	fi
	# The supervisor refuses the reboot while an update lock is held
	if curl -fsS -X POST "${BALENA_SUPERVISOR_ADDRESS}/v1/reboot?apikey=${BALENA_SUPERVISOR_API_KEY}"; then
		touch "${REBOOT_MARKER}"
	else
		echo "The supervisor refused the reboot, reboot the device later" >&2
	fi
}

backoff=${BACKOFF_MIN}
while true; do
	status=0
	run_on_host || status=$?
	case ${status} in
		"${EXIT_NOOP}")
			echo "The roots are already distrusted"
			rm -f "${REBOOT_MARKER}"
			break
			;;
		"${EXIT_PENDING}")
			echo "Dry run: the roots are still trusted. Set DRY_RUN=0 to distrust them."
			break
			;;
		"${EXIT_UNSUPPORTED}")
			echo "The root filesystem is read-only. Update balenaOS to a release that distrusts the roots." >&2
			break
			;;
		"${EXIT_PATCHED}")
			echo "Distrusted the roots"
			reboot_host
			break
			;;
	esac
	echo "The host script failed with status ${status}, see 'journalctl -u ${UNIT}' on the host. Retrying in ${backoff}s." >&2
	sleep "${backoff}"
	backoff=$((backoff * 2 > BACKOFF_MAX ? BACKOFF_MAX : backoff * 2))
done

# Idle, so the restart policy does not run the patch again
exec sleep infinity
