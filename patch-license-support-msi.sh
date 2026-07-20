#!/bin/sh
set -eu

# Override these if a future PACE package uses different identifiers:
#   OS_COMPATIBILITY_PROPERTY=COMPATIBLE_OS_VERSION \
#   SERVICE_CONFIG_ACTION=Wix4SchedServiceConfig_X86 \
#     ./patch-license-support-msi.sh LicenseSupport.msi
OS_COMPATIBILITY_PROPERTY=${OS_COMPATIBILITY_PROPERTY:-COMPATIBLE_OS_VERSION}
SERVICE_CONFIG_ACTION=${SERVICE_CONFIG_ACTION:-Wix4SchedServiceConfig_X86}
OUTPUT_SUFFIX=${OUTPUT_SUFFIX:--patched}

usage() {
    printf 'Usage: %s PATH_TO_LicenseSupport.msi\n' "${0##*/}" >&2
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

for command_name in msiinfo msibuild awk grep cp chmod mv mkdir rm dirname basename date wc df; do
    require_command "$command_name"
done

input_arg=$1
case $input_arg in
    */*) ;;
    *) input_arg=./$input_arg ;;
esac

input_dir_arg=$(dirname "$input_arg")
input_name=$(basename "$input_arg")

input_dir=$(CDPATH= cd "$input_dir_arg" 2>/dev/null && pwd -P) ||
    fail "MSI directory does not exist: $input_dir_arg"

input_path=$input_dir/$input_name

[ -f "$input_path" ] || fail "MSI does not exist or is not a regular file: $1"
[ -r "$input_path" ] || fail "MSI is not readable: $input_path"
[ -w "$input_dir" ] || fail "MSI directory is not writable: $input_dir"

case $input_name in
    *.msi|*.MSI) input_stem=${input_name%.*} ;;
    *) fail "Input file must have an .msi extension: $input_name" ;;
esac

output_name=${input_stem}${OUTPUT_SUFFIX}.msi
output_path=$input_dir/$output_name

[ "$output_path" != "$input_path" ] ||
    fail 'Output path would overwrite the input MSI. Choose a non-empty OUTPUT_SUFFIX.'

tmp_root=${TMPDIR:-/tmp}
[ -d "$tmp_root" ] || fail "Temporary directory does not exist: $tmp_root"
[ -w "$tmp_root" ] || fail "Temporary directory is not writable: $tmp_root"

temp_dir=$tmp_root/patch-license-support-msi.$$
(umask 077 && mkdir "$temp_dir") ||
    fail "Could not create temporary directory: $temp_dir"

cleanup() {
    rm -rf "$temp_dir" 2>/dev/null || :
}
trap cleanup 0 1 2 15

launch_original=$temp_dir/LaunchCondition.original.idt
launch_patched=$temp_dir/LaunchCondition.patched.idt
sequence_original=$temp_dir/InstallExecuteSequence.original.idt
sequence_patched=$temp_dir/InstallExecuteSequence.patched.idt
launch_verify=$temp_dir/LaunchCondition.verify.idt
sequence_verify=$temp_dir/InstallExecuteSequence.verify.idt
work_msi=$temp_dir/$output_name

printf 'Reading MSI tables from:\n%s\n' "$input_path"

msiinfo export "$input_path" LaunchCondition > "$launch_original" ||
    fail 'Could not export the LaunchCondition table.'

msiinfo export "$input_path" InstallExecuteSequence > "$sequence_original" ||
    fail 'Could not export the InstallExecuteSequence table.'

# Patch 1: replace the complete Windows compatibility condition with true.
awk -F '\t' -v OFS='\t' \
    -v property="$OS_COMPATIBILITY_PROPERTY" '
    NR <= 3 {
        print
        next
    }
    index($1, property) {
        old = $1
        $1 = "Installed Or 1"
        found++
        printf "Patched launch condition: %s -> %s\n", old, $1 > "/dev/stderr"
    }
    { print }
    END {
        if (found == 0) {
            printf "Launch condition containing %s was not found.\n", property > "/dev/stderr"
            exit 42
        }
        if (found > 1) {
            printf "Refusing to patch: found %d launch conditions containing %s.\n", found, property > "/dev/stderr"
            exit 43
        }
    }
' "$launch_original" > "$launch_patched" ||
    fail "Could not patch the launch condition containing $OS_COMPATIBILITY_PROPERTY."

# Patch 2: prevent WiX from scheduling unsupported service recovery settings.
awk -F '\t' -v OFS='\t' \
    -v action="$SERVICE_CONFIG_ACTION" '
    NR <= 3 {
        print
        next
    }
    $1 == action {
        old = $2
        $2 = "0"
        found++
        printf "Disabled execute-sequence action %s: %s -> 0\n", $1, old > "/dev/stderr"
    }
    { print }
    END {
        if (found == 0) {
            printf "Execute-sequence action %s was not found.\n", action > "/dev/stderr"
            exit 42
        }
        if (found > 1) {
            printf "Refusing to patch: found %d rows for action %s.\n", found, action > "/dev/stderr"
            exit 43
        }
    }
' "$sequence_original" > "$sequence_patched" ||
    fail "Could not disable execute-sequence action $SERVICE_CONFIG_ACTION."

# libmsi commits transactionally and may need space for another complete MSI.
# Give a useful warning before attempting the rewrite. This is advisory because
# filesystem allocation and compression can make exact requirements vary.
input_bytes=$(wc -c < "$input_path" | awk '{print $1}')
available_kb=$(df -Pk "$temp_dir" | awk 'NR == 2 {print $4}')
required_kb=$(awk -v bytes="$input_bytes" 'BEGIN { print int((bytes * 2 + 1023) / 1024) }')

if [ -n "$available_kb" ] && [ "$available_kb" -lt "$required_kb" ]; then
    printf '\nWarning: the temporary filesystem may not have enough free space.\n' >&2
    printf 'Available: %s KiB; recommended minimum: %s KiB.\n' "$available_kb" "$required_kb" >&2
    printf 'On Linux, retrying with TMPDIR=/dev/shm may avoid a full disk:\n' >&2
    printf '  TMPDIR=/dev/shm %s "%s"\n\n' "${0##*/}" "$1" >&2
fi

cp "$input_path" "$work_msi" ||
    fail "Could not create temporary MSI: $work_msi"
chmod u+w "$work_msi" ||
    fail "Could not make temporary MSI writable: $work_msi"

# Import both tables in one transaction. This avoids rewriting the full MSI
# twice and leaves any existing destination file untouched on failure.
if ! msibuild "$work_msi" -i "$launch_patched" "$sequence_patched"; then
    fail "Could not rewrite the MSI. Check free space with: df -h '$tmp_root'. You can retry with TMPDIR=/dev/shm."
fi

[ -f "$work_msi" ] ||
    fail "msibuild did not leave a patched MSI. Check free space on $tmp_root."

# Verify the actual rewritten database.
msiinfo export "$work_msi" LaunchCondition > "$launch_verify" ||
    fail 'Could not verify the patched LaunchCondition table.'

msiinfo export "$work_msi" InstallExecuteSequence > "$sequence_verify" ||
    fail 'Could not verify the patched InstallExecuteSequence table.'

awk -F '\t' '
    NR > 3 && $1 == "Installed Or 1" { found++ }
    END { exit(found == 1 ? 0 : 1) }
' "$launch_verify" || fail 'Launch-condition verification failed.'

awk -F '\t' -v action="$SERVICE_CONFIG_ACTION" '
    NR > 3 && $1 == action && $2 == "0" { found++ }
    END { exit(found == 1 ? 0 : 1) }
' "$sequence_verify" || fail 'Service-configuration patch verification failed.'

# Only now replace or back up the destination.
if [ -e "$output_path" ]; then
    backup_path=$output_path.bak.$(date +%Y%m%d-%H%M%S).$$
    mv "$output_path" "$backup_path" ||
        fail "Could not back up existing output: $output_path"
    printf 'Existing output moved to:\n%s\n' "$backup_path"
fi

mv "$work_msi" "$output_path" ||
    fail "Could not place patched MSI at: $output_path"
chmod u+w "$output_path" 2>/dev/null || :

printf '\nPatch complete.\n'
printf 'Input:  %s\n' "$input_path"
printf 'Output: %s\n' "$output_path"
printf '\nApplied patches:\n'
printf '  1. Windows compatibility launch condition -> Installed Or 1\n'
printf '  2. %s condition -> 0\n' "$SERVICE_CONFIG_ACTION"
printf '\nNote: modifying an MSI invalidates its original digital signature.\n'
