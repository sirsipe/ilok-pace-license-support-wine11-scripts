#!/bin/sh
set -eu

# Override these with environment variables when needed, for example:
#   PACKAGE_GUID='{...}' PACKAGE_VERSION='6.1.0' \
#     ./extract-license-support-msi.sh LicenseSupport.exe
PACKAGE_GUID=${PACKAGE_GUID:-'{A292CF9D-6241-4ADA-AEF7-4340174E7F8B}'}
PACKAGE_VERSION=${PACKAGE_VERSION:-'6.0.0'}
POLL_INTERVAL=${POLL_INTERVAL:-'0.05'}

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

require_command wine
require_command sed
require_command find
require_command wc
require_command cp
require_command mv
require_command mkdir
require_command dirname
require_command basename
require_command date
require_command sleep

wine_version_text=$(wine --version 2>&1 || :)
wine_major=$(
    printf '%s\n' "$wine_version_text" |
        sed -n 's/^[^0-9]*\([0-9][0-9]*\).*/\1/p'
)

if [ -z "$wine_major" ]; then
    fail "Could not determine Wine version from: $wine_version_text"
fi

if [ "$wine_major" -ne 11 ]; then
    fail "Wine 11 is required, but found: $wine_version_text"
fi

installer_arg=$1
case $installer_arg in
    */*) ;;
    *) installer_arg=./$installer_arg ;;
esac

installer_dir_arg=$(dirname "$installer_arg")
installer_name=$(basename "$installer_arg")

installer_dir=$(
    CDPATH= cd "$installer_dir_arg" 2>/dev/null && pwd -P
) || fail "Installer directory does not exist: $installer_dir_arg"

installer_path=$installer_dir/$installer_name

[ -f "$installer_path" ] || fail "Installer does not exist or is not a regular file: $1"
[ -r "$installer_path" ] || fail "Installer is not readable: $installer_path"
[ -w "$installer_dir" ] || fail "Installer directory is not writable: $installer_dir"

WINEPREFIX=${WINEPREFIX:-"$HOME/.wine"}
export WINEPREFIX

package_cache=$WINEPREFIX/drive_c/ProgramData/Package\ Cache
cache_prefix=${PACKAGE_GUID}v${PACKAGE_VERSION}.
output_path=$installer_dir/LicenseSupport.msi

tmp_root=${TMPDIR:-/tmp}
temp_dir=$tmp_root/extract-license-support-msi.$$

(umask 077 && mkdir "$temp_dir") || fail "Could not create temporary directory: $temp_dir"

marker_file=$temp_dir/marker
done_file=$temp_dir/done
result_file=$temp_dir/result
temp_output=$installer_dir/.LicenseSupport.msi.extracting.$$

: > "$marker_file"
: > "$result_file"
rm -f "$done_file" "$temp_output"

watcher_pid=

cleanup() {
    : > "$done_file" 2>/dev/null || :

    if [ -n "$watcher_pid" ] && kill -0 "$watcher_pid" 2>/dev/null; then
        kill "$watcher_pid" 2>/dev/null || :
        wait "$watcher_pid" 2>/dev/null || :
    fi

    rm -f "$temp_output" 2>/dev/null || :
    rm -rf "$temp_dir" 2>/dev/null || :
}

trap cleanup 0 1 2 15

# Convert a decimal string to a form safe for POSIX test integer comparisons.
# This strips leading zeroes without using non-POSIX arithmetic extensions.
normalise_integer() {
    normalised_integer=$1

    while [ "${normalised_integer#0}" != "$normalised_integer" ]; do
        normalised_integer=${normalised_integer#0}
    done

    [ -n "$normalised_integer" ] || normalised_integer=0
}

# Sets BEST_BUILD and BEST_PATH. When the argument is 1, only MSI files newer
# than marker_file are considered. When it is 0, all matching cached files are
# considered. If multiple builds exist, the numerically largest build wins.
select_best_candidate() {
    fresh_only=$1
    BEST_BUILD=-1
    BEST_PATH=

    for candidate_dir in "$package_cache"/"$cache_prefix"*; do
        [ -d "$candidate_dir" ] || continue

        candidate_base=${candidate_dir##*/}
        case $candidate_base in
            "$cache_prefix"*) ;;
            *) continue ;;
        esac

        candidate_build=${candidate_base#"$cache_prefix"}
        case $candidate_build in
            ''|*[!0-9]*) continue ;;
        esac

        candidate_msi=$candidate_dir/LicenseSupport.msi
        [ -s "$candidate_msi" ] || continue

        if [ "$fresh_only" -eq 1 ]; then
            fresh_match=$(find "$candidate_msi" -prune -newer "$marker_file" -print 2>/dev/null || :)
            [ -n "$fresh_match" ] || continue
        fi

        normalise_integer "$candidate_build"
        candidate_build_number=$normalised_integer

        if [ "$candidate_build_number" -gt "$BEST_BUILD" ]; then
            BEST_BUILD=$candidate_build_number
            BEST_PATH=$candidate_msi
        fi
    done
}

copy_candidate() {
    source_path=$1
    build_number=$2

    source_size=$(wc -c < "$source_path" 2>/dev/null || printf '0')
    case $source_size in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ "$source_size" -gt 0 ] || return 1

    cp "$source_path" "$temp_output" 2>/dev/null || return 1

    copied_size=$(wc -c < "$temp_output" 2>/dev/null || printf '0')
    if [ "$copied_size" != "$source_size" ]; then
        rm -f "$temp_output"
        return 1
    fi

    if [ "$backup_done" -eq 0 ] && [ -e "$output_path" ]; then
        backup_path=$output_path.bak.$(date +%Y%m%d-%H%M%S).$$
        mv "$output_path" "$backup_path"
        printf 'Existing output moved to: %s\n' "$backup_path"
        backup_done=1
    fi

    mv -f "$temp_output" "$output_path"
    captured_build=$build_number
    backup_done=1
    printf '%s\n' "$captured_build" > "$result_file"

    printf 'Captured PACE License Support MSI build %s:\n%s\n' \
        "$build_number" "$output_path"
}

watch_and_copy_msi() {
    captured_build=-1
    backup_done=0

    while [ ! -e "$done_file" ]; do
        select_best_candidate 0

        if [ -n "$BEST_PATH" ] && [ "$BEST_BUILD" -gt "$captured_build" ]; then
            copy_candidate "$BEST_PATH" "$BEST_BUILD" || :
        fi

        sleep "$POLL_INTERVAL"
    done

    # One final fresh scan after the installer exits.
    select_best_candidate 1
    if [ -n "$BEST_PATH" ] && [ "$BEST_BUILD" -gt "$captured_build" ]; then
        copy_candidate "$BEST_PATH" "$BEST_BUILD" || :
    fi

    # Burn may reuse an existing cached payload without changing its timestamp.
    # In that case, use the largest matching cached build as a fallback.
    if [ "$captured_build" -lt 0 ]; then
        select_best_candidate 0

        if [ -n "$BEST_PATH" ]; then
            printf '%s\n' \
                'Warning: no newly written MSI was found; using the largest existing cached build.' >&2
            copy_candidate "$BEST_PATH" "$BEST_BUILD" || :
        fi
    fi

    rm -f "$temp_output"
    [ "$captured_build" -ge 0 ]
}

cat <<'MESSAGE'
Launching iLok License Support Installer. This is EXPECTED TO FAIL, but is a
necessary step to obtain the internal .msi package. Follow the installer to the
end and then close it when it fails.
MESSAGE

printf 'Continue [Y/n]? '
IFS= read -r answer || answer=

case $answer in
    ''|y|Y|yes|YES|Yes) ;;
    *)
        printf 'Cancelled.\n'
        exit 0
        ;;
esac

printf 'Wine: %s\n' "$wine_version_text"
printf 'Installer: %s\n' "$installer_path"
printf 'Wine prefix: %s\n' "$WINEPREFIX"
printf 'Watching cache pattern: %s/%s<build>/LicenseSupport.msi\n' \
    "$package_cache" "$cache_prefix"

watch_and_copy_msi &
watcher_pid=$!

set +e
(
    cd "$installer_dir" && wine "$installer_path"
)
installer_status=$?
set -e

: > "$done_file"

set +e
wait "$watcher_pid"
watcher_status=$?
set -e
watcher_pid=

if [ "$watcher_status" -ne 0 ]; then
    fail 'The installer exited, but no matching LicenseSupport.msi was captured from the Wine package cache.'
fi

IFS= read -r captured_build < "$result_file" || captured_build=
[ -n "$captured_build" ] || fail 'The MSI was copied, but its build number could not be determined.'

printf '\nExtraction complete.\n'
printf 'MSI: %s\n' "$output_path"
printf 'PACE version: %s.%s\n' "$PACKAGE_VERSION" "$captured_build"

if [ "$installer_status" -eq 0 ]; then
    printf '%s\n' \
        'Note: the installer exited successfully, although failure was expected for this extraction workflow.'
else
    printf 'Installer exit status: %s (expected to be non-zero in this workflow).\n' \
        "$installer_status"
fi
