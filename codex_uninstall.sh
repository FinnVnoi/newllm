#!/usr/bin/env bash
set -euo pipefail

TARGET_CATALOG_NAME='legacy_direct_model_catalog.json'
STATE_FILE_NAME='codex_custom_endpoint_unix_state'
BACKUP_DIRECTORY_NAME='codex_custom_endpoint_unix_backup'
ENV_FILE_NAME='codex_custom_endpoint.env'
PROFILE_BEGIN='# >>> codex-custom-endpoint >>>'
PROFILE_END='# <<< codex-custom-endpoint <<<'

die() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

CODEX_HOME_PATH="${CODEX_HOME:-$HOME/.codex}"
CONFIG_PATH="$CODEX_HOME_PATH/config.toml"
TARGET_CATALOG_PATH="$CODEX_HOME_PATH/$TARGET_CATALOG_NAME"
STATE_PATH="$CODEX_HOME_PATH/$STATE_FILE_NAME"
BACKUP_DIRECTORY="$CODEX_HOME_PATH/$BACKUP_DIRECTORY_NAME"
ENV_FILE_PATH="$CODEX_HOME_PATH/$ENV_FILE_NAME"

state_get() {
    key="$1"
    awk -v wanted="$key" '
        index($0, wanted "=") == 1 {
            print substr($0, length(wanted) + 2)
            exit
        }
    ' "$STATE_PATH"
}

sha256_file() {
    path="$1"
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$path" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$path" | awk '{print $1}'
    else
        die 'Neither sha256sum nor shasum is available.'
    fi
}

save_changed_file() {
    path="$1"
    label="$2"
    timestamp="$(date '+%Y%m%d_%H%M%S')"
    safety_path="$path.before_codex_uninstall_${timestamp}_${label}_$$.bak"
    cp -p "$path" "$safety_path"
    case "$path" in
        "$ENV_FILE_PATH")
            chmod 600 "$safety_path"
            ;;
    esac
    printf '%s\n' "$safety_path"
}

remove_profile_block() {
    profile_path="$1"
    profile_existed="$2"
    [ -f "$profile_path" ] || return

    profile_temporary_path="$(mktemp "${TMPDIR:-/tmp}/codex-profile.XXXXXX")"
    awk -v begin="$PROFILE_BEGIN" -v end="$PROFILE_END" '
        $0 == begin { skipping = 1; next }
        $0 == end { skipping = 0; next }
        !skipping { print }
    ' "$profile_path" > "$profile_temporary_path"

    if [ "$profile_existed" = '0' ] && ! grep -q '[^[:space:]]' "$profile_temporary_path"; then
        rm -f "$profile_path" "$profile_temporary_path"
    else
        cp "$profile_temporary_path" "$profile_path"
        rm -f "$profile_temporary_path"
    fi
}

if [ ! -f "$STATE_PATH" ]; then
    printf 'Nothing to uninstall: install state not found at %s\n' "$STATE_PATH"
    exit 0
fi

[ "$(state_get schema_version)" = '1' ] || die "Unsupported install state: $STATE_PATH"
[ "$BACKUP_DIRECTORY" = "$CODEX_HOME_PATH/$BACKUP_DIRECTORY_NAME" ] || die 'Invalid backup directory.'
[ -d "$BACKUP_DIRECTORY" ] || die "Backup directory not found: $BACKUP_DIRECTORY"

CONFIG_EXISTED="$(state_get config_existed)"
CATALOG_EXISTED="$(state_get catalog_existed)"
ENV_FILE_EXISTED="$(state_get env_file_existed)"
SHELL_PROFILE_EXISTED="$(state_get shell_profile_existed)"
SHELL_PROFILE_PATH="$(state_get shell_profile_path)"
INSTALLED_CONFIG_SHA256="$(state_get installed_config_sha256)"
INSTALLED_CATALOG_SHA256="$(state_get installed_catalog_sha256)"
INSTALLED_ENV_SHA256="$(state_get installed_env_sha256)"

[ "$CONFIG_EXISTED" = '0' ] || [ -f "$BACKUP_DIRECTORY/config.toml.original" ] || die 'Original config backup is missing.'
[ "$CATALOG_EXISTED" = '0' ] || [ -f "$BACKUP_DIRECTORY/$TARGET_CATALOG_NAME.original" ] || die 'Original catalog backup is missing.'
[ "$ENV_FILE_EXISTED" = '0' ] || [ -f "$BACKUP_DIRECTORY/$ENV_FILE_NAME.original" ] || die 'Original environment backup is missing.'

SAFETY_COPIES=''
if [ -f "$CONFIG_PATH" ] && [ -n "$INSTALLED_CONFIG_SHA256" ] && [ "$(sha256_file "$CONFIG_PATH")" != "$INSTALLED_CONFIG_SHA256" ]; then
    SAFETY_COPIES="$SAFETY_COPIES$(save_changed_file "$CONFIG_PATH" 'config_changed')"$'\n'
fi
if [ -f "$TARGET_CATALOG_PATH" ] && [ -n "$INSTALLED_CATALOG_SHA256" ] && [ "$(sha256_file "$TARGET_CATALOG_PATH")" != "$INSTALLED_CATALOG_SHA256" ]; then
    SAFETY_COPIES="$SAFETY_COPIES$(save_changed_file "$TARGET_CATALOG_PATH" 'catalog_changed')"$'\n'
fi
if [ -f "$ENV_FILE_PATH" ] && [ -n "$INSTALLED_ENV_SHA256" ] && [ "$(sha256_file "$ENV_FILE_PATH")" != "$INSTALLED_ENV_SHA256" ]; then
    SAFETY_COPIES="$SAFETY_COPIES$(save_changed_file "$ENV_FILE_PATH" 'environment_changed')"$'\n'
fi

if [ "$CONFIG_EXISTED" = '1' ]; then
    cp -p "$BACKUP_DIRECTORY/config.toml.original" "$CONFIG_PATH"
else
    rm -f "$CONFIG_PATH"
fi

if [ "$CATALOG_EXISTED" = '1' ]; then
    cp -p "$BACKUP_DIRECTORY/$TARGET_CATALOG_NAME.original" "$TARGET_CATALOG_PATH"
else
    rm -f "$TARGET_CATALOG_PATH"
fi

if [ "$ENV_FILE_EXISTED" = '1' ]; then
    cp -p "$BACKUP_DIRECTORY/$ENV_FILE_NAME.original" "$ENV_FILE_PATH"
else
    rm -f "$ENV_FILE_PATH"
fi

remove_profile_block "$SHELL_PROFILE_PATH" "$SHELL_PROFILE_EXISTED"

unset CODEX_BASE_URL CODEX_API_KEY CODEX_MODEL CODEX_REASONING_EFFORT || true

rm -rf "$BACKUP_DIRECTORY"
rm -f "$STATE_PATH"

printf '\nCodex custom endpoint installation was removed and the original state was restored.\n'
if [ -n "$SAFETY_COPIES" ]; then
    printf 'Files changed after installation were saved before restoration:\n%s' "$SAFETY_COPIES"
fi
printf 'Open a new terminal and restart Codex to load the restored environment.\n'
