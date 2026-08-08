#!/bin/bash

## Copyright (C) 2025 ENCRYPTED SUPPORT LLC <adrelanos@whonix.org>
## See the file COPYING for copying conditions.

## Asserts the MODE of the files the installer writes, not just its exit code.
## An installer that exits 0 while leaving a private key world-readable is the
## exact defect this covers, so a pass here means the mode was inspected.

set -o errexit
set -o nounset
set -o pipefail
set -o errtrace
shopt -s inherit_errexit
shopt -s shift_verbose

error_handler() {
   local exit_code="$?"
   printf '%s\n' "ERROR: exit_code: ${exit_code} | BASH_COMMAND: ${BASH_COMMAND}"
   exit 1
}

trap error_handler ERR

if [ "$(id -u)" != "0" ]; then
   printf '%s\n' "ERROR: must run as root; the installer chowns to the Tor user." >&2
   exit 1
fi

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
installer="${script_dir}/../../../bin/anon-server-to-client-install"

if ! test -x "${installer}" ; then
   printf '%s\n' "ERROR: installer '${installer}' not found or not executable." >&2
   exit 1
fi

test_root="$(mktemp --directory)"

cleanup_handler() {
   safe-rm -r -f -- "${test_root}"
}

trap cleanup_handler EXIT

tests_total=0
tests_failed=0

check_mode() {
   local label="$1" expected="$2" path="$3" actual
   tests_total=$(( tests_total + 1 ))
   if ! test -e "${path}" ; then
      printf '%s\n' "FAIL: ${label}: '${path}' does not exist."
      tests_failed=$(( tests_failed + 1 ))
      return 0
   fi
   actual="$(stat --format=%a -- "${path}")"
   if [ "${actual}" = "${expected}" ]; then
      printf '%s\n' "PASS: ${label}: mode ${actual}"
   else
      printf '%s\n' "FAIL: ${label}: mode ${actual}, expected ${expected}"
      tests_failed=$(( tests_failed + 1 ))
   fi
}

run_installer() {
   local sourcefile="$1"
   ## 'tor_user=root': debian-tor need not exist on the test host, and the
   ## assertion is about the mode, not about which user owns the file.
   ## The unit commands are stubbed so no Tor has to be running.
   sourcefile="${sourcefile}" \
   tor_user="root" \
   tor_group="root" \
   tor_dir="${test_root}/var-lib-tor" \
   torconfdir="${test_root}/torrc.d" \
   torconffile="${test_root}/torrc.d/60_client_onion_auth_dir.conf" \
   unitcmd="true" \
   unitruntestcmd="true" \
   user_name="nobody" \
      "${installer}" >/dev/null
}

mkdir --parents -- "${test_root}/var-lib-tor" "${test_root}/torrc.d"

## Case 1: a world-readable sourcefile must NOT stay world-readable once
## installed. 'cp' preserves the source mode, which is how the key leaked.
printf '%s\n' "descriptor:x25519:AAAA" > "${test_root}/1.auth_private"
chmod 0644 -- "${test_root}/1.auth_private"
run_installer "${test_root}/1.auth_private"
check_mode "newly installed key" "600" "${test_root}/var-lib-tor/authdir/1.auth_private"

## Case 2: a key left world-readable by an EARLIER run gets tightened on the
## next run. A code-only fix would leave already deployed keys exposed.
printf '%s\n' "descriptor:x25519:BBBB" > "${test_root}/var-lib-tor/authdir/9.auth_private"
chmod 0644 -- "${test_root}/var-lib-tor/authdir/9.auth_private"
run_installer "${test_root}/1.auth_private"
check_mode "pre-existing key from an earlier run" "600" "${test_root}/var-lib-tor/authdir/9.auth_private"

printf '%s\n' "---"
printf '%s\n' "${tests_total} run, $(( tests_total - tests_failed )) pass, ${tests_failed} fail, 0 skip"

if [ "${tests_failed}" != "0" ]; then
   exit 1
fi
