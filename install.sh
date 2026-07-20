#!/bin/sh
set -eu

usage() {
    printf 'Usage: %s PATH_TO_LicenseSupport.exe\n' "${0##*/}" >&2
}

fail() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

if [ "$#" -ne 1 ]; then
    usage
    exit 2
fi

for command_name in wine winetricks msiinfo msibuild sed grep dirname basename mkdir rm sleep; do
    require_command "$command_name"
done

wine_version_text=$(wine --version 2>&1 || :)
wine_major=$(printf '%s\n' "$wine_version_text" | sed -n 's/^[^0-9]*\([0-9][0-9]*\).*/\1/p')

[ -n "$wine_major" ] || fail "Could not determine Wine version from: $wine_version_text"
[ "$wine_major" -eq 11 ] || fail "Wine 11.x is required, but found: $wine_version_text"

installer_arg=$1
case $installer_arg in
    */*) ;;
    *) installer_arg=./$installer_arg ;;
esac

installer_dir_arg=$(dirname "$installer_arg")
installer_name=$(basename "$installer_arg")
installer_dir=$(CDPATH= cd "$installer_dir_arg" 2>/dev/null && pwd -P) ||
    fail "Installer directory does not exist: $installer_dir_arg"
installer_path=$installer_dir/$installer_name

[ -f "$installer_path" ] || fail "Installer does not exist: $1"
[ -r "$installer_path" ] || fail "Installer is not readable: $installer_path"
[ -w "$installer_dir" ] || fail "Installer directory is not writable: $installer_dir"

script_dir=$(CDPATH= cd "$(dirname "$0")" 2>/dev/null && pwd -P) ||
    fail 'Could not determine the script directory.'
extract_script=$script_dir/extract-license-support-msi.sh
patch_script=$script_dir/patch-license-support-msi.sh

[ -r "$extract_script" ] || fail "Missing sibling script: $extract_script"
[ -r "$patch_script" ] || fail "Missing sibling script: $patch_script"

WINEPREFIX=${WINEPREFIX:-"$HOME/.wine"}
export WINEPREFIX

msi_path=$installer_dir/LicenseSupport.msi
patched_msi=$installer_dir/LicenseSupport-patched.msi
install_log=$installer_dir/LicenseSupport-patched-install.log

temp_dir=${TMPDIR:-/tmp}/install-license-support.$$
(umask 077 && mkdir "$temp_dir") || fail "Could not create temporary directory: $temp_dir"

cleanup() {
    rm -rf "$temp_dir" 2>/dev/null || :
}
trap cleanup 0 1 2 15

printf 'Wine: %s\n' "$wine_version_text"
printf 'Wine prefix: %s\n' "$WINEPREFIX"
printf 'Installer: %s\n\n' "$installer_path"

# The extraction script presents the confirmation prompt and captures the MSI
# before the expected failure of the unmodified installer.
sh "$extract_script" "$installer_path"

printf '\nInstalling Microsoft Visual C++ 2015-2022 runtime...\n'
winetricks -q --force vcrun2022 ||
    fail 'winetricks failed to install vcrun2022.'

patch_tmp=${TMPDIR:-}
if [ -z "$patch_tmp" ]; then
    if [ -d /dev/shm ] && [ -w /dev/shm ]; then
        patch_tmp=/dev/shm
    else
        patch_tmp=/tmp
    fi
fi

printf '\nPatching extracted MSI...\n'
TMPDIR=$patch_tmp sh "$patch_script" "$msi_path"

[ -f "$patched_msi" ] || fail "Patched MSI was not created: $patched_msi"

printf '\nInstalling patched PACE License Support...\n'
rm -f "$install_log"

set +e
wine msiexec /i "$patched_msi" \
    BURNMSIINSTALL=1 \
    /L*v "$install_log"
install_status=$?
set -e

if [ "$install_status" -ne 0 ]; then
    printf '\nInstallation failed with exit status %s.\n' "$install_status" >&2
    printf 'MSI log: %s\n' "$install_log" >&2
    exit 1
fi

# Give the service a moment to finish starting.
sleep 3

service_query=$temp_dir/service-query.txt
service_start=$temp_dir/service-start.txt
registry_query=$temp_dir/registry-query.txt
tasklist_output=$temp_dir/tasklist.txt

service_registered=no
service_running=no
registry_present=no
process_running=no

if WINEDEBUG=-all wine sc query PACELicenseDServices >"$service_query" 2>&1; then
    service_registered=yes
    if grep -qi 'RUNNING' "$service_query"; then
        service_running=yes
    else
        WINEDEBUG=-all wine sc start PACELicenseDServices >"$service_start" 2>&1 || :
        sleep 3
        if WINEDEBUG=-all wine sc query PACELicenseDServices >"$service_query" 2>&1 &&
           grep -qi 'RUNNING' "$service_query"; then
            service_running=yes
        fi
    fi
fi

if WINEDEBUG=-all wine reg query \
    'HKLM\System\CurrentControlSet\Services\PACELicenseDServices' \
    /s >"$registry_query" 2>&1; then
    registry_present=yes
fi

if WINEDEBUG=-all wine tasklist >"$tasklist_output" 2>&1 &&
   grep -qi 'LDSvc\.exe' "$tasklist_output"; then
    process_running=yes
fi

printf '\nVerification\n'
printf '  MSI installation:     PASS\n'
printf '  Service registered:   %s\n' "$( [ "$service_registered" = yes ] && printf PASS || printf FAIL )"
printf '  Service running:      %s\n' "$( [ "$service_running" = yes ] && printf PASS || printf FAIL )"
printf '  Service registry key: %s\n' "$( [ "$registry_present" = yes ] && printf PASS || printf FAIL )"
printf '  LDSvc.exe process:    %s\n' "$( [ "$process_running" = yes ] && printf PASS || printf FAIL )"
printf '  MSI log:              %s\n' "$install_log"

if [ "$service_registered" = yes ] &&
   [ "$service_running" = yes ] &&
   [ "$registry_present" = yes ] &&
   [ "$process_running" = yes ]; then
    printf '\nPACE License Support installed successfully.\n'
    exit 0
fi

printf '\nThe MSI completed, but PACE License Support is not fully operational.\n' >&2
printf 'Inspect the MSI log and run:\n' >&2
printf '  wine sc query PACELicenseDServices\n' >&2
printf '  wine tasklist | grep -i LDSvc\n' >&2
exit 1
