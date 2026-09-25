#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_ROOT="$(cd "$SCRIPT_DIRECTORY/.." && pwd)"
PACKAGE_JSON="$REPOSITORY_ROOT/package.json"
VERSION_PATTERN='^v?[0-9]+\.[0-9]+\.[0-9]+$'

fail() {
  printf 'ERROR: %s\n' "$1" >&2
  exit 1
}

read_package_version() {
  local package_path="$1"
  local version_line_count
  local version

  IFS=$'\t' read -r version_line_count version < <(awk '
    function record_version(value) {
      count += 1
      version = value
    }

    {
      for (position = 1; position <= length($0); position += 1) {
        character = substr($0, position, 1)

        if (in_string) {
          if (escaped) {
            escaped = 0
          } else if (character == "\\") {
            escaped = 1
          } else if (character == "\"") {
            in_string = 0
            if (string_depth == 1 && string_value == "version") {
              remainder = substr($0, position + 1)
              if (remainder ~ /^[[:space:]]*:[[:space:]]*"[^"\\]*"/) {
                sub(/^[[:space:]]*:[[:space:]]*"/, "", remainder)
                sub(/".*$/, "", remainder)
                record_version(remainder)
              }
            }
            string_value = ""
          } else {
            string_value = string_value character
          }
          continue
        }

        if (character == "\"") {
          in_string = 1
          string_depth = depth
          string_value = ""
        } else if (character == "{") {
          depth += 1
        } else if (character == "}") {
          depth -= 1
        }
      }
    }

    END {
      printf "%d\t%s\n", count + 0, version
    }
  ' "$package_path")

  if [[ "$version_line_count" != '1' ]]; then
    fail "package.json: expected exactly one root version line, found $version_line_count."
  fi

  if [[ -z "$version" ]]; then
    fail 'package.json: version is missing or empty.'
  fi

  printf '%s' "$version"
}

copy_to_clipboard() {
  local value="$1"
  local system

  system="$(uname -s)"
  if [[ "$system" == 'Darwin' ]] && command -v pbcopy >/dev/null 2>&1; then
    printf '%s' "$value" | pbcopy
    printf 'pbcopy'
    return 0
  fi

  if [[ "$system" == 'Linux' ]]; then
    if command -v wl-copy >/dev/null 2>&1; then
      printf '%s' "$value" | wl-copy
      printf 'wl-copy'
      return 0
    fi

    if command -v xclip >/dev/null 2>&1; then
      printf '%s' "$value" | xclip -selection clipboard
      printf 'xclip'
      return 0
    fi
  fi

  return 1
}

if [[ ! -f "$PACKAGE_JSON" ]]; then
  fail "package.json was not found at $PACKAGE_JSON."
fi

if [[ $# -gt 1 ]]; then
  fail 'Usage: ./scripts/prepare-release.sh [X.Y.Z|vX.Y.Z]'
fi

if [[ $# -eq 1 ]]; then
  requested_version="$1"
else
  read -r -p 'Release version (X.Y.Z or vX.Y.Z): ' requested_version
fi

if [[ ! "$requested_version" =~ $VERSION_PATTERN ]]; then
  fail "Invalid version \"$requested_version\". Use stable X.Y.Z or vX.Y.Z."
fi

next_version="${requested_version#v}"
next_tag="v$next_version"
current_version="$(read_package_version "$PACKAGE_JSON")"

if [[ "$current_version" == "$next_version" ]]; then
  fail "Version $next_tag is already current; no files were changed."
fi

git_status="$(git -C "$REPOSITORY_ROOT" status --short --untracked-files=all -- package.json)"
if [[ -n "$git_status" ]]; then
  fail 'package.json is dirty; commit or stash it before preparing a release.'
fi

backup_file="$(mktemp "${TMPDIR:-/tmp}/prepare-release-backup.XXXXXX")"
updated_file="$(mktemp "${TMPDIR:-/tmp}/prepare-release-updated.XXXXXX")"
cp "$PACKAGE_JSON" "$backup_file"
written=0

cleanup() {
  local status=$?

  if [[ "$status" -ne 0 && "$written" -eq 1 ]]; then
    if ! cp "$backup_file" "$PACKAGE_JSON"; then
      printf 'ERROR: Release preparation failed and package.json could not be restored.\n' >&2
    fi
  fi

  rm -f "$backup_file" "$updated_file"
  exit "$status"
}

trap cleanup EXIT

awk -v next_version="$next_version" '
  function fail_update(message) {
    print "package.json: " message > "/dev/stderr"
    exit 1
  }

  {
    line = $0
    replacement_start = 0
    replacement_length = 0

    for (position = 1; position <= length(line); position += 1) {
      character = substr(line, position, 1)

      if (in_string) {
        if (escaped) {
          escaped = 0
        } else if (character == "\\") {
          escaped = 1
        } else if (character == "\"") {
          in_string = 0
          if (string_depth == 1 && string_value == "version") {
            remainder = substr(line, position + 1)
            prefix_match = match(remainder, /^[[:space:]]*:[[:space:]]*"/)
            if (prefix_match == 1) {
              value_start = position + prefix_match + RLENGTH
              value_remainder = substr(remainder, RLENGTH + 1)
              value_match = match(value_remainder, /^[^"\\]*"/)
              if (value_match == 1) {
                replacement_start = value_start
                replacement_length = RLENGTH - 1
                version_count += 1
              }
            }
          }
          string_value = ""
        } else {
          string_value = string_value character
        }
        continue
      }

      if (character == "\"") {
        in_string = 1
        string_depth = depth
        string_value = ""
      } else if (character == "{") {
        depth += 1
      } else if (character == "}") {
        depth -= 1
      }
    }

    if (replacement_start > 0) {
      print substr(line, 1, replacement_start - 1) next_version substr(line, replacement_start + replacement_length)
    } else {
      print line
    }
  }

  END {
    if (version_count != 1) {
      fail_update("expected exactly one root version value, found " (version_count + 0) ".")
    }
  }
' "$PACKAGE_JSON" > "$updated_file"

updated_version="$(read_package_version "$updated_file")"
if [[ "$updated_version" != "$next_version" ]]; then
  fail "package.json: version was not updated to $next_version."
fi

cp "$updated_file" "$PACKAGE_JSON"
written=1

stage_command='git add -- package.json'
commit_command="git commit -m \"chore: prepare release $next_tag\""
clipboard_command="$stage_command && $commit_command"

printf 'Prepared release %s.\n' "$next_tag"
printf 'Updated files:\n'
printf '%s\n' '- package.json'
printf 'Commit message: chore: prepare release %s\n' "$next_tag"
printf 'Next command:\n%s\n' "$clipboard_command"

if clipboard_provider="$(copy_to_clipboard "$clipboard_command")"; then
  printf 'Copied the stage-and-commit command to the clipboard using %s.\n' "$clipboard_provider"
else
  printf 'Clipboard is unavailable; use the printed stage-and-commit command.\n'
fi

trap - EXIT
rm -f "$backup_file" "$updated_file"
