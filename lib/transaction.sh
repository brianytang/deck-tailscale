#!/usr/bin/env bash
# Sourced by tailscale.sh after its ownership checks and temporary directory setup.
defaults=${defaults:?Missing defaults path}
unit_dir=${unit_dir:?Missing unit directory}
dropin_dir=${dropin_dir:?Missing drop-in directory}
profile=${profile:?Missing profile path}
keep=${keep:?Missing retention path}
marker=${marker:?Missing ownership marker}
tmp=${tmp:?Missing transaction staging directory}
bin_dir=${bin_dir:?Missing binary directory}
transaction=0
was_active=0
was_enabled=0
previous=
managed_paths=("$defaults" "$unit_dir/tailscaled.service" "$dropin_dir/10-steamos.conf" "$profile" "$keep" "$marker")
existed=()

begin_transaction() {
  local index
  mkdir "$tmp/backup"
  for index in "${!managed_paths[@]}"; do
    existed[index]=0
    if [[ -e ${managed_paths[index]} ]]; then
      cp -a -- "${managed_paths[index]}" "$tmp/backup/$index"
      existed[index]=1
    fi
  done
  previous=$(readlink "$bin_dir/current" 2>/dev/null || true)
  if systemctl is-active --quiet tailscaled; then was_active=1; fi
  if systemctl is-enabled --quiet tailscaled; then was_enabled=1; fi
  transaction=1
}

rollback() {
  local index failed=0
  printf 'Restoring the previous installation...\n' >&2
  systemctl stop tailscaled >/dev/null 2>&1 || true
  for index in "${!managed_paths[@]}"; do
    rm -f -- "${managed_paths[index]}" || failed=1
    if [[ ${existed[index]} == 1 ]]; then
      cp -a -- "$tmp/backup/$index" "${managed_paths[index]}" || failed=1
    fi
  done
  if [[ -n $previous ]]; then
    ln -s "$previous" "$bin_dir/.rollback.$$" && mv -Tf -- "$bin_dir/.rollback.$$" "$bin_dir/current" || failed=1
  else
    rm -f -- "$bin_dir/current" || failed=1
  fi
  systemctl daemon-reload || failed=1
  if (( was_enabled )); then
    systemctl enable tailscaled || failed=1
  else
    # Disable while a unit exists, or remove just our enablement link after a
    # failed first installation (systemctl disable would report unit not found).
    if [[ -e "$unit_dir/tailscaled.service" ]]; then
      systemctl disable tailscaled || failed=1
    else
      rm -f -- "$unit_dir/multi-user.target.wants/tailscaled.service" || failed=1
    fi
  fi
  if (( was_active )); then systemctl restart tailscaled || failed=1; fi
  (( failed == 0 )) || printf 'ERROR: Rollback was incomplete. Inspect journalctl -u tailscaled before retrying.\n' >&2
}

on_error() {
  local status=${1:-$?}
  trap - ERR
  set +e
  if (( transaction )); then rollback; fi
  printf 'Installation failed. Existing login state is preserved.\n' >&2
  exit "$status"
}
trap on_error ERR
trap 'on_error 130' INT
trap 'on_error 143' TERM
