#!/usr/bin/env bash
# Offline integration tests: the installer runs as the ordinary invoking user.
set -euo pipefail

repo="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "$(/usr/bin/id -u)" == 0 ]]; then
  echo 'Run these tests as an ordinary user, never as root.' >&2
  exit 1
fi
suite="$(mktemp -d)"
trap 'rm -rf -- "$suite"' EXIT
mkdir -p "$suite/mock"
cp "$repo/tests/mock-command.py" "$suite/mock-command.py"
chmod +x "$suite/mock-command.py"
for command in id uname curl jq systemctl systemd-sysext stat chown install sha256sum rm mkdir cp mv ln chmod; do
  ln -s "$suite/mock-command.py" "$suite/mock/$command"
done

fail() { echo "  $*" >&2; return 1; }
assert_file() { [[ -f "$1" ]] || fail "missing file: $1"; }
assert_absent() { [[ ! -e "$1" && ! -L "$1" ]] || fail "unexpected path: $1"; }
assert_contains() { grep -Fq -- "$2" "$1" || fail "$1 does not contain: $2"; }
assert_no_service_change() {
  if grep -Eq '^systemctl (stop|disable|enable|start|restart)( |$)' "$TEST_EVENTS"; then
    fail 'service changed before downloaded files were validated'
  fi
}

reset_fixture() {
  export TEST_ROOT="$suite/$1"
  export TEST_EVENTS="$TEST_ROOT/events"
  export TEST_FIXTURES="$TEST_ROOT/fixtures"
  export TEST_ARCH=aarch64 TEST_VERSION=1.2.3 TEST_OWNER=0
  unset TEST_BAD_CHECKSUM TEST_BAD_METADATA TEST_DOWNLOAD_FAILURE TEST_SERVICE_FAILURE TEST_UNSAFE_OWNER_PATH TEST_CHECKSUM_NO_NEWLINE TEST_VENDOR_UNIT
  mkdir -p "$TEST_ROOT" "$TEST_ROOT/tmp" "$TEST_ROOT/cwd" "$TEST_ROOT/etc/default" \
    "$TEST_ROOT/etc/profile.d" "$TEST_ROOT/etc/systemd/system" \
    "$TEST_ROOT/etc/atomic-update.conf.d" "$TEST_ROOT/var/lib" "$TEST_ROOT/run" "$TEST_ROOT/home"
  : > "$TEST_EVENTS"
  python3 "$repo/tests/prepare-fixtures.py" "$repo" "$TEST_ROOT"
}

run_script() {
  local script=$1
  shift
  (cd "$TEST_ROOT/cwd" && env PATH="$suite/mock:$PATH" TMPDIR="$TEST_ROOT/tmp" \
    bash "$TEST_ROOT/$script" "$@") > "$TEST_ROOT/output" 2>&1
}

install_ok() {
  if ! run_script tailscale.sh; then
    cat "$TEST_ROOT/output" >&2
    fail 'installer unexpectedly failed'
  fi
}

install_fails() {
  if run_script tailscale.sh; then
    cat "$TEST_ROOT/output" >&2
    fail 'installer unexpectedly succeeded'
  fi
}

bin_root() { printf '%s/home/.tailscale-bin' "$TEST_ROOT"; }
state_root() { printf '%s/var/lib/tailscale' "$TEST_ROOT"; }

assert_install() {
  local binaries
  binaries="$(bin_root)"
  [[ -L "$binaries/current" ]] || fail 'current release is not a symlink'
  [[ "$(readlink "$binaries/current")" == releases/release.* ]] || fail 'current release target is not relative'
  assert_contains "$binaries/current/tailscale" "tailscale-$TEST_VERSION-$2"
  assert_contains "$binaries/current/tailscaled" "tailscaled-$TEST_VERSION-$2"
  [[ "$(/usr/bin/stat -c %a "$binaries")" == 755 ]] || fail 'binary directory mode must be 755'
  [[ "$(/usr/bin/stat -c %a "$(state_root)")" == 700 ]] || fail 'state directory mode must be 700'
  assert_file "$TEST_ROOT/etc/systemd/system/tailscaled.service"
  assert_file "$TEST_ROOT/etc/systemd/system/tailscaled.service.d/10-steamos.conf"
  assert_file "$TEST_ROOT/etc/default/tailscaled"
  assert_file "$TEST_ROOT/etc/profile.d/tailscale.sh"
  assert_contains "$TEST_ROOT/etc/systemd/system/tailscaled.service.d/10-steamos.conf" '/current/tailscaled'
  assert_contains "$TEST_ROOT/etc/systemd/system/tailscaled.service.d/10-steamos.conf" 'Environment=PORT=41641'
  assert_contains "$TEST_ROOT/etc/profile.d/tailscale.sh" '/.tailscale-bin/current'
  assert_file "$binaries/managed-by-deck-tailscale"
  for path in /etc/default/tailscaled /etc/profile.d/tailscale.sh /etc/systemd/system/tailscaled.service \
    /etc/systemd/system/tailscaled.service.d/10-steamos.conf /etc/systemd/system/multi-user.target.wants/tailscaled.service; do
    assert_contains "$TEST_ROOT/etc/atomic-update.conf.d/tailscale.conf" "$path"
  done
  assert_contains "$TEST_EVENTS" "tailscale_${TEST_VERSION}_${2}.tgz"
  assert_contains "$TEST_EVENTS" 'sha256sum '
  # Production ownership must be explicitly set, even though the test user cannot chown root.
  grep -Eq '^chown .*root|^chown .*0:0|^install .* (-o|--owner) (root|0)' "$TEST_EVENTS" || fail 'no root ownership operation recorded'
  assert_file "$TEST_ROOT/service-active"
  assert_file "$TEST_ROOT/service-enabled"
}

test_architectures() {
  local arch target
  for arch in aarch64 arm64 x86_64 amd64; do
    reset_fixture "arch-$arch"
    export TEST_ARCH=$arch
    case "$arch" in aarch64|arm64) target=arm64 ;; *) target=amd64 ;; esac
    install_ok
    assert_install "$arch" "$target"
  done
}

test_unsupported_architecture() {
  reset_fixture unsupported
  export TEST_ARCH=riscv64
  install_fails
  assert_no_service_change
  assert_absent "$(bin_root)/current"
}

test_checksum_without_newline() {
  reset_fixture checksum-without-newline
  export TEST_CHECKSUM_NO_NEWLINE=1
  install_ok
  assert_install aarch64 arm64
}

seed_preserved_files() {
  mkdir -p "$(state_root)" "$TEST_ROOT/etc/systemd/system/tailscaled.service.d"
  printf 'login-state-do-not-remove\n' > "$(state_root)/tailscaled.state"
  printf 'PORT=12345\nFLAGS="--custom-flag"\n' > "$TEST_ROOT/etc/default/tailscaled"
  printf '[Service]\nEnvironment=CUSTOM=yes\n' > "$TEST_ROOT/etc/systemd/system/tailscaled.service.d/90-custom.conf"
  cp "$(state_root)/tailscaled.state" "$TEST_ROOT/saved-state"
  cp "$TEST_ROOT/etc/default/tailscaled" "$TEST_ROOT/saved-defaults"
  cp "$TEST_ROOT/etc/systemd/system/tailscaled.service.d/90-custom.conf" "$TEST_ROOT/saved-custom"
}

assert_preserved_files() {
  cmp "$(state_root)/tailscaled.state" "$TEST_ROOT/saved-state"
  cmp "$TEST_ROOT/etc/default/tailscaled" "$TEST_ROOT/saved-defaults"
  cmp "$TEST_ROOT/etc/systemd/system/tailscaled.service.d/90-custom.conf" "$TEST_ROOT/saved-custom"
}

test_update_idempotence() {
  reset_fixture update
  seed_preserved_files
  install_ok
  assert_preserved_files
  export TEST_VERSION=1.2.4
  install_ok
  assert_install aarch64 arm64
  assert_preserved_files
  install_ok
  assert_preserved_files
  [[ "$(grep -c '/.tailscale-bin/current' "$TEST_ROOT/etc/profile.d/tailscale.sh")" == 1 ]] || fail 'profile entries duplicated'
  local verified stopped
  verified=$(grep -n '^sha256sum ' "$TEST_EVENTS" | tail -1 | cut -d: -f1)
  stopped=$(grep -n '^systemctl stop ' "$TEST_EVENTS" | tail -1 | cut -d: -f1)
  [[ -n "$verified" && -n "$stopped" && "$verified" -lt "$stopped" ]] || fail 'update did not verify checksum before stopping daemon'
}

test_failed_downloads() {
  local condition
  for condition in TEST_BAD_CHECKSUM TEST_BAD_METADATA TEST_DOWNLOAD_FAILURE; do
    reset_fixture "$condition"
    seed_preserved_files
    install_ok
    local current
    current=$(readlink "$(bin_root)/current")
    : > "$TEST_EVENTS"
    export "$condition=1" TEST_VERSION=1.2.4
    install_fails
    assert_no_service_change
    [[ "$(readlink "$(bin_root)/current")" == "$current" ]] || fail 'failed download replaced active release'
    assert_preserved_files
    assert_file "$TEST_ROOT/service-active"
  done
}

test_missing_archive_member() {
  reset_fixture missing-member
  seed_preserved_files
  install_ok
  local current
  current=$(readlink "$(bin_root)/current")
  touch "$TEST_ROOT/omit-binary"
  python3 "$repo/tests/prepare-fixtures.py" "$repo" "$TEST_ROOT"
  : > "$TEST_EVENTS"
  export TEST_VERSION=1.2.4
  install_fails
  assert_no_service_change
  [[ "$(readlink "$(bin_root)/current")" == "$current" ]] || fail 'incomplete archive replaced active release'
  assert_preserved_files
}

test_wrong_binary_version() {
  reset_fixture wrong-version
  seed_preserved_files
  install_ok
  local current
  current=$(readlink "$(bin_root)/current")
  touch "$TEST_ROOT/wrong-version"
  python3 "$repo/tests/prepare-fixtures.py" "$repo" "$TEST_ROOT"
  : > "$TEST_EVENTS"
  export TEST_VERSION=1.2.4
  install_fails
  assert_no_service_change
  [[ "$(readlink "$(bin_root)/current")" == "$current" ]] || fail 'wrong binary version replaced active release'
}

test_unsafe_install_paths() {
  reset_fixture symlink
  mkdir -p "$TEST_ROOT/unrelated"
  ln -s "$TEST_ROOT/unrelated" "$(bin_root)"
  install_fails
  assert_no_service_change
  [[ -L "$(bin_root)" ]] || fail 'unsafe symlink was replaced'
  reset_fixture unowned
  mkdir -p "$(bin_root)"
  export TEST_OWNER=1000
  install_fails
  assert_no_service_change
  reset_fixture writable
  mkdir -p "$(bin_root)"
  chmod 0777 "$(bin_root)"
  install_fails
  assert_no_service_change
  reset_fixture config-symlink
  printf 'unrelated config\n' > "$TEST_ROOT/unrelated"
  ln -s "$TEST_ROOT/unrelated" "$TEST_ROOT/etc/default/tailscaled"
  install_fails
  assert_no_service_change
  assert_contains "$TEST_ROOT/unrelated" 'unrelated config'
  reset_fixture config-owner
  printf 'PORT=12345\n' > "$TEST_ROOT/etc/default/tailscaled"
  export TEST_UNSAFE_OWNER_PATH=/etc/default/tailscaled
  install_fails
  assert_no_service_change
  reset_fixture unrelated-unit
  printf '[Service]\nExecStart=/bin/true\n' > "$TEST_ROOT/etc/systemd/system/tailscaled.service"
  install_fails
  assert_no_service_change
  assert_contains "$TEST_ROOT/etc/systemd/system/tailscaled.service" 'ExecStart=/bin/true'
  reset_fixture dangling-current
  mkdir -p "$(bin_root)/releases"
  ln -s releases/release.missing "$(bin_root)/current"
  install_fails
  assert_no_service_change
  [[ "$(readlink "$(bin_root)/current")" == releases/release.missing ]] || fail 'dangling current release was modified'
  reset_fixture vendor-unit
  export TEST_VENDOR_UNIT=1
  install_fails
  assert_no_service_change
  assert_absent "$(bin_root)/current"
}

test_service_failures() {
  local operation
  for operation in daemon-reload stop enable restart; do
    reset_fixture "service-$operation"
    if [[ "$operation" == stop ]]; then
      install_ok
    fi
    export TEST_SERVICE_FAILURE=$operation
    install_fails
    assert_contains "$TEST_EVENTS" "systemctl $operation"
    if [[ "$operation" != stop ]]; then
      assert_absent "$(bin_root)/current"
      assert_absent "$(bin_root)/managed-by-deck-tailscale"
      assert_absent "$TEST_ROOT/etc/systemd/system/tailscaled.service"
    fi
  done
}

test_update_rolls_back() {
  local active enabled operation
  for active in yes no; do
    for enabled in yes no; do
      for operation in stop enable restart; do
        if [[ "$active" == no && "$operation" == stop ]]; then continue; fi
        reset_fixture "rollback-$active-$enabled-$operation"
        seed_preserved_files
        install_ok
        local current
        current=$(readlink "$(bin_root)/current")
        cp "$TEST_ROOT/etc/systemd/system/tailscaled.service" "$TEST_ROOT/saved-unit"
        cp "$TEST_ROOT/etc/systemd/system/tailscaled.service.d/10-steamos.conf" "$TEST_ROOT/saved-override"
        if [[ "$active" == no ]]; then rm -f "$TEST_ROOT/service-active"; fi
        if [[ "$enabled" == no ]]; then rm -f "$TEST_ROOT/service-enabled"; fi
        export TEST_VERSION=1.2.4 TEST_SERVICE_FAILURE=$operation
        install_fails
        [[ "$(readlink "$(bin_root)/current")" == "$current" ]] || fail 'failed update did not restore prior release'
        cmp "$TEST_ROOT/etc/systemd/system/tailscaled.service" "$TEST_ROOT/saved-unit"
        cmp "$TEST_ROOT/etc/systemd/system/tailscaled.service.d/10-steamos.conf" "$TEST_ROOT/saved-override"
        assert_preserved_files
        if [[ "$active" == yes ]]; then assert_file "$TEST_ROOT/service-active"; else assert_absent "$TEST_ROOT/service-active"; fi
        if [[ "$enabled" == yes ]]; then assert_file "$TEST_ROOT/service-enabled"; else assert_absent "$TEST_ROOT/service-enabled"; fi
      done
    done
  done
}

test_uninstall_idempotence() {
  reset_fixture uninstall
  seed_preserved_files
  install_ok
  run_script uninstall.sh
  assert_absent "$(bin_root)"
  assert_absent "$TEST_ROOT/etc/systemd/system/tailscaled.service"
  assert_absent "$TEST_ROOT/etc/systemd/system/tailscaled.service.d/10-steamos.conf"
  cmp "$(state_root)/tailscaled.state" "$TEST_ROOT/saved-state"
  cmp "$TEST_ROOT/etc/systemd/system/tailscaled.service.d/90-custom.conf" "$TEST_ROOT/saved-custom"
  run_script uninstall.sh
  cmp "$(state_root)/tailscaled.state" "$TEST_ROOT/saved-state"
  cmp "$TEST_ROOT/etc/systemd/system/tailscaled.service.d/90-custom.conf" "$TEST_ROOT/saved-custom"
}

tests=(test_architectures test_unsupported_architecture test_checksum_without_newline test_update_idempotence \
  test_failed_downloads test_missing_archive_member test_wrong_binary_version test_unsafe_install_paths \
  test_service_failures test_update_rolls_back test_uninstall_idempotence)
printf '1..%s\n' "${#tests[@]}"
index=0
failed=0
for test in "${tests[@]}"; do
  index=$((index + 1))
  # Calling the function in an if-condition would disable errexit in its body.
  set +e
  (set -e; "$test")
  status=$?
  set -e
  if [[ "$status" == 0 ]]; then
    printf 'ok %s - %s\n' "$index" "$test"
  else
    printf 'not ok %s - %s\n' "$index" "$test"
    failed=$((failed + 1))
  fi
done
[[ "$failed" == 0 ]]
