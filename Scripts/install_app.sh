#!/bin/bash
# Transactional install of a verified app bundle into a destination root.
#
# Production shape (the only one `just install` uses):
#   install_app.sh --source build/Usage.app --destination-root /Applications
#
# Test shape (used only by `just test-install`, never against /Applications):
#   install_app.sh --source <app> --destination-root <dir> --test-root <dir> \
#       [--fail-at move-replacement|after-replace|verify|launch|restore] \
#       [--verifier <cmd>] [--launcher <cmd>]
#
# The transaction: stage a copy beside the destination, verify it, quit the running app, move the
# previous app aside, move the staged app in, verify and launch the installed app, and roll the
# previous app back on any failure. A failure that cannot roll back preserves both recovery
# artifacts and prints their exact paths.
set -euo pipefail

app_name="Usage"
source_app=""
destination_root=""
test_root=""
fail_at=""
verifier=""
launcher=""

fail() {
  printf '%s\n' "$1" >&2
  exit "${2:-1}"
}

canonical() {
  python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$1"
}

while [ $# -gt 0 ]; do
  case "$1" in
  --app-name) app_name="${2:?}" && shift 2 ;;
  --source) source_app="${2:?}" && shift 2 ;;
  --destination-root) destination_root="${2:?}" && shift 2 ;;
  --test-root) test_root="${2:?}" && shift 2 ;;
  --fail-at) fail_at="${2:?}" && shift 2 ;;
  --verifier) verifier="${2:?}" && shift 2 ;;
  --launcher) launcher="${2:?}" && shift 2 ;;
  *) fail "unknown argument: $1" 2 ;;
  esac
done

[ -n "${source_app}" ] || fail "--source is required" 2
[ -n "${destination_root}" ] || fail "--destination-root is required" 2
[ -d "${source_app}" ] || fail "source app does not exist: ${source_app}" 2

# --- Mode guards -----------------------------------------------------------------------------
# Failure injection and fake tools exist only for the rollback test-bench. They are accepted only
# when the canonical test root sits beneath the canonical per-user temporary directory, the
# canonical destination root sits beneath the test root, and neither path traverses a symlink.
# A production run rejects every injection flag outright.
if [ -n "${test_root}" ]; then
  canon_tmp="$(canonical "${TMPDIR:-/tmp}")"
  canon_test_root="$(canonical "${test_root}")"
  canon_destination="$(canonical "${destination_root}")"
  [ "${canon_test_root}" = "${test_root%/}" ] ||
    fail "refusing --test-root that traverses a symlink or is not canonical: ${test_root}" 2
  [ "${canon_destination}" = "${destination_root%/}" ] ||
    fail "refusing a destination root that traverses a symlink: ${destination_root}" 2
  case "${canon_test_root}" in
  "${canon_tmp}"/*) ;;
  *) fail "refusing --test-root outside the per-user temporary directory: ${test_root}" 2 ;;
  esac
  case "${canon_destination}" in
  "${canon_test_root}"/*) ;;
  *) fail "refusing a destination root outside the test root: ${destination_root}" 2 ;;
  esac
  case "${fail_at}" in
  "" | move-replacement | after-replace | verify | launch | restore) ;;
  *) fail "unknown --fail-at seam: ${fail_at}" 2 ;;
  esac
else
  [ -z "${fail_at}" ] || fail "--fail-at requires --test-root" 2
  [ -z "${verifier}" ] || fail "--verifier requires --test-root" 2
  [ -z "${launcher}" ] || fail "--launcher requires --test-root" 2
fi

destination="${destination_root}/${app_name}.app"
process_pattern="${destination}/Contents/MacOS/${app_name}"

# --- Verification ----------------------------------------------------------------------------
# The installed bundle must carry the very signature the verified source carried: a valid,
# non-ad-hoc signature with the same designated requirement and CDHash. Copying must not have
# changed the signed artifact.
cdhash_of() {
  local signature
  signature="$(codesign --display --verbose=4 "$1" 2>&1)" || return 1
  awk '/^CDHash=/{sub(/^CDHash=/, ""); if (!found) { print; found=1 }}' <<<"${signature}"
}

requirement_of() {
  codesign --display --requirements - "$1" 2>/dev/null | sed -n 's/^designated => //p'
}

verify_bundle() {
  local candidate="$1" signature
  # The restore seam needs a reachable rollback: it first fails this post-replacement audit and
  # then fails the restore move itself inside restore_previous.
  if { [ "${fail_at}" = "verify" ] || [ "${fail_at}" = "restore" ]; } && [ "$2" = "installed" ]; then
    printf 'injected verification failure at %s\n' "${candidate}" >&2
    return 1
  fi
  if [ -n "${verifier}" ]; then
    "${verifier}" "${candidate}"
    return
  fi
  codesign --verify --deep --strict "${candidate}"
  if ! signature="$(codesign --display --verbose=2 "${candidate}" 2>&1)"; then
    printf 'could not inspect the signature at %s\n' "${candidate}" >&2
    return 1
  fi
  if grep -q '^Signature=adhoc$' <<<"${signature}"; then
    printf '%s is ad-hoc signed; an ad-hoc identity cannot hold a durable Keychain grant\n' \
      "${candidate}" >&2
    return 1
  fi
  [ "$(cdhash_of "${candidate}")" = "${source_cdhash}" ] ||
    {
      printf 'CDHash changed between source and %s\n' "${candidate}" >&2
      return 1
    }
  [ "$(requirement_of "${candidate}")" = "${source_requirement}" ] ||
    {
      printf 'designated requirement changed at %s\n' "${candidate}" >&2
      return 1
    }
}

launch_and_check() {
  local app="$1"
  if [ "${fail_at}" = "launch" ]; then
    printf 'injected launch failure for %s\n' "${app}" >&2
    return 1
  fi
  if [ -n "${launcher}" ]; then
    "${launcher}" "${app}"
    return
  fi
  local before launched candidate
  before="$(pgrep -f "${process_pattern}" || true)"
  open -n "${app}"
  launched=""
  for _ in $(seq 1 20); do
    while IFS= read -r candidate; do
      [ -z "${candidate}" ] && continue
      if ! grep -qx "${candidate}" <<<"${before}"; then
        launched="${candidate}"
        break
      fi
    done < <(pgrep -f "${process_pattern}" || true)
    [ -n "${launched}" ] && break
    sleep 0.1
  done
  if [ -z "${launched}" ]; then
    printf '%s did not start. Check the latest crash report.\n' "${app_name}" >&2
    return 1
  fi
  sleep 1
  local running
  running="$(pgrep -f "${process_pattern}" || true)"
  if ! grep -qx "${launched}" <<<"${running}"; then
    printf '%s exited during startup. Check the latest crash report.\n' "${app_name}" >&2
    return 1
  fi
}

if [ -z "${verifier}" ]; then
  source_cdhash="$(cdhash_of "${source_app}")"
  source_requirement="$(requirement_of "${source_app}")"
  [ -n "${source_cdhash}" ] || fail "could not read the source app's CDHash" 1
fi

# --- Staging ---------------------------------------------------------------------------------
if ! stage_root="$(mktemp -d "${destination_root}/.${app_name}.install.XXXXXX")"; then
  fail "could not create a staging directory in ${destination_root}; check its permissions" 1
fi
case "${stage_root}" in
"${destination_root}/.${app_name}.install."*) ;;
*) fail "refusing unexpected staging path: ${stage_root}" 1 ;;
esac
staged_app="${stage_root}/${app_name}.app"
previous_app="${stage_root}/${app_name}.previous.app"
failed_app="${stage_root}/${app_name}.failed.app"
had_previous=false
preserve_stage=false

cleanup() {
  if [ "${preserve_stage}" = false ]; then
    /bin/rm -rf "${stage_root}"
  fi
}
trap cleanup EXIT

ditto "${source_app}" "${staged_app}"
verify_bundle "${staged_app}" staged

# --- Quit the running app --------------------------------------------------------------------
if pgrep -q -f "${process_pattern}"; then
  osascript -e "quit app \"${app_name}\"" >/dev/null 2>&1 ||
    printf '%s did not accept the quit request; waiting for it to exit.\n' "${app_name}" >&2
  for _ in $(seq 1 20); do
    pgrep -q -f "${process_pattern}" || break
    sleep 0.5
  done
  running="$(pgrep -f "${process_pattern}" || true)"
  if [ -n "${running}" ]; then
    fail "${app_name} is still running (PID ${running//$'\n'/, }). Nothing was installed." 1
  fi
fi

# --- Replace ---------------------------------------------------------------------------------
restore_previous() {
  local reason="$1"
  if [ -d "${destination}" ] && ! mv "${destination}" "${failed_app}"; then
    preserve_stage=true
    fail "install failed: ${reason} The replacement remains at ${destination} and requires manual recovery." 1
  fi
  if [ "${had_previous}" = true ]; then
    if [ "${fail_at}" = "restore" ] || ! mv "${previous_app}" "${destination}"; then
      preserve_stage=true
      printf 'install failed: %s\n' "${reason}" >&2
      printf 'the previous app remains recoverable at %s\n' "${previous_app}" >&2
      printf 'the rejected replacement remains at %s\n' "${failed_app}" >&2
      exit 1
    fi
    printf 'install failed: %s The previous app was restored.\n' "${reason}" >&2
  else
    printf 'install failed: %s No previous app was replaced.\n' "${reason}" >&2
  fi
  exit 1
}

if [ -d "${destination}" ]; then
  mv "${destination}" "${previous_app}"
  had_previous=true
fi

if [ "${fail_at}" = "move-replacement" ]; then
  restore_previous "injected failure moving the staged app into place."
fi
if ! mv "${staged_app}" "${destination}"; then
  restore_previous "could not move the staged app into ${destination}."
fi
if [ "${fail_at}" = "after-replace" ]; then
  restore_previous "injected failure directly after replacement."
fi

if ! verify_bundle "${destination}" installed; then
  restore_previous "the installed app failed its signature audit."
fi
if ! launch_and_check "${destination}"; then
  restore_previous "the replacement did not survive startup."
fi

printf 'installed, audited, and launched %s\n' "${destination}"
