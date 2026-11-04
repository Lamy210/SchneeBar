#!/usr/bin/env bash
# Shared real-app smoke fixture for GitHub-hosted macOS CI / Release Preview.
# Refuses nonempty or symlinked Application Support paths; cleans up only
# the named isolated test fixture and the directories created by setup.
set -euo pipefail

if [[ -z "${RUNNER_TEMP:-}" || -z "${HOME:-}" || "${RUNNER_ENVIRONMENT:-}" != "github-hosted" ]]; then
  echo "Refusing smoke fixture changes outside a GitHub-hosted runner." >&2
  exit 1
fi

case "${1:-}" in
  setup)
    set -euo pipefail
    umask 077
    
    owner="$HOME/Library/Application Support/SchneeBar"
    root="$owner/ExternalWidgets"
    fixture="$root/schneebar-ci-smoke.json"
    sentinel="$root/.schneebar-ci-smoke-ready"
    owner_state="$RUNNER_TEMP/schneebar-ci-created-owner"
    root_state="$RUNNER_TEMP/schneebar-ci-created-root"
    
    rm -f -- "$owner_state" "$root_state"
    
    if [[ -L "$owner" || -L "$root" ]]; then
      echo "Refusing symlinked SchneeBar Application Support storage." >&2
      exit 1
    fi
    
    if [[ -e "$root" ]]; then
      [[ -d "$root" ]] || {
        echo "ExternalWidgets exists but is not a directory." >&2
        exit 1
      }
      if [[ -n "$(find "$root" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
        echo "Refusing to overwrite non-empty ExternalWidgets storage." >&2
        exit 1
      fi
    else
      if [[ ! -e "$owner" ]]; then
        mkdir -p -- "$owner"
        : > "$owner_state"
      elif [[ ! -d "$owner" ]]; then
        echo "SchneeBar Application Support owner is not a directory." >&2
        exit 1
      fi
    
      mkdir -- "$root"
      : > "$root_state"
    fi
    
    cat > "$fixture" <<'JSON'
    {
      "schemaVersion": 1,
      "id": "external.ci.smoke",
      "displayName": "CI External Widget",
      "defaultEnabled": false,
      "defaultOrder": 1200,
      "defaultRepresentation": "normal",
      "visibility": {
        "kind": "always"
      },
      "refresh": {
        "kind": "manual"
      },
      "snapshot": {
        "severity": "nominal",
        "priority": "normal",
        "compact": {
          "text": "CI",
          "systemImage": "checkmark.circle",
          "accessibilityLabel": "CI external widget"
        },
        "normal": {
          "text": "CI smoke",
          "systemImage": "checkmark.circle",
          "accessibilityLabel": "CI external widget smoke"
        }
      }
    }
    JSON
    : > "$sentinel"
    ;;
  cleanup)
    set -euo pipefail
    
    owner="$HOME/Library/Application Support/SchneeBar"
    root="$owner/ExternalWidgets"
    fixture="$root/schneebar-ci-smoke.json"
    sentinel="$root/.schneebar-ci-smoke-ready"
    owner_state="$RUNNER_TEMP/schneebar-ci-created-owner"
    root_state="$RUNNER_TEMP/schneebar-ci-created-root"
    
    rm -f -- "$fixture" "$sentinel"
    
    if [[ -f "$root_state" ]]; then
      rmdir -- "$root" 2>/dev/null || true
    fi
    if [[ -f "$owner_state" ]]; then
      rmdir -- "$owner" 2>/dev/null || true
    fi
    
    rm -f -- "$owner_state" "$root_state"
    ;;
  *)
    echo "Usage: bash Scripts/external_widget_smoke_fixture.sh setup|cleanup" >&2
    exit 2
    ;;
esac
