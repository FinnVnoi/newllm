#!/usr/bin/env bash
set -euo pipefail

DEFAULT_ENDPOINT='https://codex.finnvnoi.top/backend-api/codex'
DEFAULT_MODEL='gpt-5.6-sol'
DEFAULT_EFFORT='xhigh'
PROVIDER_ID='codex'
PROVIDER_NAME='CODEX'
API_KEY_VARIABLE='CODEX_API_KEY'
TARGET_CATALOG_NAME='legacy_direct_model_catalog.json'
STATE_FILE_NAME='codex_custom_endpoint_unix_state'
BACKUP_DIRECTORY_NAME='codex_custom_endpoint_unix_backup'
ENV_FILE_NAME='codex_custom_endpoint.env'
PROFILE_BEGIN='# >>> codex-custom-endpoint >>>'
PROFILE_END='# <<< codex-custom-endpoint <<<'
NON_INTERACTIVE=0

die() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

usage() {
    printf '%s\n' \
        'Usage: ./codex_install.sh [--non-interactive]' \
        '' \
        'Without arguments, the installer prompts for endpoint, API key, model, and effort.' \
        '--non-interactive uses the bundled defaults and requires CODEX_API_KEY to be set.'
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --non-interactive)
            NON_INTERACTIVE=1
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "Unknown argument: $1"
            ;;
    esac
    shift
done

SCRIPT_DIRECTORY="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CODEX_HOME_PATH="${CODEX_HOME:-$HOME/.codex}"
CONFIG_PATH="$CODEX_HOME_PATH/config.toml"
TARGET_CATALOG_PATH="$CODEX_HOME_PATH/$TARGET_CATALOG_NAME"
STATE_PATH="$CODEX_HOME_PATH/$STATE_FILE_NAME"
BACKUP_DIRECTORY="$CODEX_HOME_PATH/$BACKUP_DIRECTORY_NAME"
ENV_FILE_PATH="$CODEX_HOME_PATH/$ENV_FILE_NAME"
BUNDLED_CATALOG_PATH="$SCRIPT_DIRECTORY/$TARGET_CATALOG_NAME"
LEGACY_FALLBACK_PATH="$CODEX_HOME_PATH/legacy-direct-model-catalog.json"

choose_shell_profile() {
    shell_name="$(basename "${SHELL:-sh}")"
    case "$shell_name" in
        zsh)
            printf '%s\n' "$HOME/.zshrc"
            ;;
        bash)
            if [ "$(uname -s)" = 'Darwin' ]; then
                printf '%s\n' "$HOME/.bash_profile"
            else
                printf '%s\n' "$HOME/.bashrc"
            fi
            ;;
        *)
            printf '%s\n' "$HOME/.profile"
            ;;
    esac
}

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

shell_quote() {
    value="$1"
    escaped="$(printf '%s' "$value" | sed "s/'/'\\\\''/g")"
    printf "'%s'" "$escaped"
}

toml_quote() {
    value="$1"
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    value="${value//$'\t'/\\t}"
    value="${value//$'\r'/\\r}"
    value="${value//$'\n'/\\n}"
    printf '"%s"' "$value"
}

read_with_default() {
    label="$1"
    default_value="$2"
    printf '%s [%s]: ' "$label" "$default_value" >&2
    if ! IFS= read -r entered_value; then
        die "Could not read $label."
    fi
    if [ -z "$entered_value" ]; then
        printf '%s\n' "$default_value"
    else
        printf '%s\n' "$entered_value"
    fi
}

read_api_key() {
    existing_value="$1"
    if [ "$NON_INTERACTIVE" -eq 1 ]; then
        [ -n "$existing_value" ] || die 'CODEX_API_KEY is not set.'
        printf '%s\n' "$existing_value"
        return
    fi

    if [ -n "$existing_value" ]; then
        printf 'API key [Enter = keep current CODEX_API_KEY]: ' >&2
    else
        printf 'API key: ' >&2
    fi
    if ! IFS= read -r -s entered_value; then
        printf '\n' >&2
        die 'Could not read API key.'
    fi
    printf '\n' >&2

    if [ -z "$entered_value" ]; then
        [ -n "$existing_value" ] || die 'API key cannot be empty because CODEX_API_KEY is not set.'
        printf '%s\n' "$existing_value"
    else
        printf '%s\n' "$entered_value"
    fi
}

write_state() {
    state_temporary_path="$(mktemp "$CODEX_HOME_PATH/.codex-state.XXXXXX")"
    {
        printf 'schema_version=1\n'
        printf 'config_existed=%s\n' "$CONFIG_EXISTED"
        printf 'catalog_existed=%s\n' "$CATALOG_EXISTED"
        printf 'env_file_existed=%s\n' "$ENV_FILE_EXISTED"
        printf 'shell_profile_existed=%s\n' "$SHELL_PROFILE_EXISTED"
        printf 'shell_profile_path=%s\n' "$SHELL_PROFILE_PATH"
        printf 'installed_config_sha256=%s\n' "$INSTALLED_CONFIG_SHA256"
        printf 'installed_catalog_sha256=%s\n' "$INSTALLED_CATALOG_SHA256"
        printf 'installed_env_sha256=%s\n' "$INSTALLED_ENV_SHA256"
    } > "$state_temporary_path"
    chmod 600 "$state_temporary_path"
    mv -f "$state_temporary_path" "$STATE_PATH"
}

write_config() {
    model_line="model = $(toml_quote "$MODEL")"
    provider_line="model_provider = $(toml_quote "$PROVIDER_ID")"
    effort_line="model_reasoning_effort = $(toml_quote "$EFFORT")"
    catalog_line="model_catalog_json = $(toml_quote "$TARGET_CATALOG_PATH")"
    provider_name_line="name = $(toml_quote "$PROVIDER_NAME")"
    provider_url_line="base_url = $(toml_quote "$ENDPOINT")"
    provider_env_line="env_key = $(toml_quote "$API_KEY_VARIABLE")"
    provider_wire_line="wire_api = $(toml_quote 'responses')"
    config_input="$CONFIG_PATH"
    [ -f "$config_input" ] || config_input='/dev/null'
    config_temporary_path="$(mktemp "$CODEX_HOME_PATH/.config.toml.XXXXXX")"

    MODEL_LINE="$model_line" \
    PROVIDER_LINE="$provider_line" \
    EFFORT_LINE="$effort_line" \
    CATALOG_LINE="$catalog_line" \
    PROVIDER_NAME_LINE="$provider_name_line" \
    PROVIDER_URL_LINE="$provider_url_line" \
    PROVIDER_ENV_LINE="$provider_env_line" \
    PROVIDER_WIRE_LINE="$provider_wire_line" \
    LC_ALL=C awk '
        function emit_missing_top() {
            if (!seen_model) print ENVIRON["MODEL_LINE"]
            if (!seen_provider) print ENVIRON["PROVIDER_LINE"]
            if (!seen_effort) print ENVIRON["EFFORT_LINE"]
            if (!seen_catalog) print ENVIRON["CATALOG_LINE"]
        }
        function emit_missing_provider() {
            if (!seen_provider_name) print ENVIRON["PROVIDER_NAME_LINE"]
            if (!seen_provider_url) print ENVIRON["PROVIDER_URL_LINE"]
            if (!seen_provider_env) print ENVIRON["PROVIDER_ENV_LINE"]
            if (!seen_provider_wire) print ENVIRON["PROVIDER_WIRE_LINE"]
        }
        BEGIN {
            top_finished = 0
            in_provider = 0
            provider_seen = 0
        }
        {
            line = $0
            is_table = line ~ /^[[:space:]]*\[/

            if (is_table) {
                if (!top_finished) {
                    emit_missing_top()
                    top_finished = 1
                }
                if (in_provider) {
                    emit_missing_provider()
                    in_provider = 0
                }
                if (line ~ /^[[:space:]]*\[[[:space:]]*model_providers\.codex[[:space:]]*\][[:space:]]*(#.*)?$/) {
                    provider_seen = 1
                    in_provider = 1
                }
                print line
                next
            }

            if (!top_finished) {
                if (line ~ /^[[:space:]]*model[[:space:]]*=/) {
                    if (!seen_model) print ENVIRON["MODEL_LINE"]
                    seen_model = 1
                    next
                }
                if (line ~ /^[[:space:]]*model_provider[[:space:]]*=/) {
                    if (!seen_provider) print ENVIRON["PROVIDER_LINE"]
                    seen_provider = 1
                    next
                }
                if (line ~ /^[[:space:]]*model_reasoning_effort[[:space:]]*=/) {
                    if (!seen_effort) print ENVIRON["EFFORT_LINE"]
                    seen_effort = 1
                    next
                }
                if (line ~ /^[[:space:]]*model_catalog_json[[:space:]]*=/) {
                    if (!seen_catalog) print ENVIRON["CATALOG_LINE"]
                    seen_catalog = 1
                    next
                }
                print line
                next
            }

            if (in_provider) {
                if (line ~ /^[[:space:]]*name[[:space:]]*=/) {
                    if (!seen_provider_name) print ENVIRON["PROVIDER_NAME_LINE"]
                    seen_provider_name = 1
                    next
                }
                if (line ~ /^[[:space:]]*base_url[[:space:]]*=/) {
                    if (!seen_provider_url) print ENVIRON["PROVIDER_URL_LINE"]
                    seen_provider_url = 1
                    next
                }
                if (line ~ /^[[:space:]]*env_key[[:space:]]*=/) {
                    if (!seen_provider_env) print ENVIRON["PROVIDER_ENV_LINE"]
                    seen_provider_env = 1
                    next
                }
                if (line ~ /^[[:space:]]*wire_api[[:space:]]*=/) {
                    if (!seen_provider_wire) print ENVIRON["PROVIDER_WIRE_LINE"]
                    seen_provider_wire = 1
                    next
                }
            }

            print line
        }
        END {
            if (!top_finished) {
                emit_missing_top()
            }
            if (in_provider) {
                emit_missing_provider()
            } else if (!provider_seen) {
                print ""
                print "[model_providers.codex]"
                print ENVIRON["PROVIDER_NAME_LINE"]
                print ENVIRON["PROVIDER_URL_LINE"]
                print ENVIRON["PROVIDER_ENV_LINE"]
                print ENVIRON["PROVIDER_WIRE_LINE"]
            }
        }
    ' "$config_input" > "$config_temporary_path"

    if [ -f "$CONFIG_PATH" ]; then
        cp "$config_temporary_path" "$CONFIG_PATH"
        rm -f "$config_temporary_path"
    else
        mv -f "$config_temporary_path" "$CONFIG_PATH"
    fi
}

write_environment_file() {
    env_temporary_path="$(mktemp "$CODEX_HOME_PATH/.codex-env.XXXXXX")"
    {
        printf 'export CODEX_BASE_URL=%s\n' "$(shell_quote "$ENDPOINT")"
        printf 'export CODEX_API_KEY=%s\n' "$(shell_quote "$API_KEY")"
        printf 'export CODEX_MODEL=%s\n' "$(shell_quote "$MODEL")"
        printf 'export CODEX_REASONING_EFFORT=%s\n' "$(shell_quote "$EFFORT")"
    } > "$env_temporary_path"
    chmod 600 "$env_temporary_path"
    mv -f "$env_temporary_path" "$ENV_FILE_PATH"
}

write_shell_profile_block() {
    profile_directory="$(dirname "$SHELL_PROFILE_PATH")"
    mkdir -p "$profile_directory"
    profile_temporary_path="$(mktemp "${TMPDIR:-/tmp}/codex-profile.XXXXXX")"

    if [ -f "$SHELL_PROFILE_PATH" ]; then
        awk -v begin="$PROFILE_BEGIN" -v end="$PROFILE_END" '
            $0 == begin { skipping = 1; next }
            $0 == end { skipping = 0; next }
            !skipping { print }
        ' "$SHELL_PROFILE_PATH" > "$profile_temporary_path"
    else
        : > "$profile_temporary_path"
    fi

    {
        printf '%s\n' "$PROFILE_BEGIN"
        printf '[ -f %s ] && . %s\n' "$(shell_quote "$ENV_FILE_PATH")" "$(shell_quote "$ENV_FILE_PATH")"
        printf '%s\n' "$PROFILE_END"
    } >> "$profile_temporary_path"

    if [ -f "$SHELL_PROFILE_PATH" ]; then
        cp "$profile_temporary_path" "$SHELL_PROFILE_PATH"
        rm -f "$profile_temporary_path"
    else
        mv -f "$profile_temporary_path" "$SHELL_PROFILE_PATH"
    fi
}

if [ -f "$BUNDLED_CATALOG_PATH" ]; then
    CATALOG_SOURCE_PATH="$BUNDLED_CATALOG_PATH"
elif [ -f "$LEGACY_FALLBACK_PATH" ]; then
    CATALOG_SOURCE_PATH="$LEGACY_FALLBACK_PATH"
else
    die "Missing $TARGET_CATALOG_NAME beside the installer and no legacy fallback exists in $CODEX_HOME_PATH."
fi

[ -s "$CATALOG_SOURCE_PATH" ] || die "Catalog is empty: $CATALOG_SOURCE_PATH"
grep -q '"models"' "$CATALOG_SOURCE_PATH" || die "Catalog does not contain a models field: $CATALOG_SOURCE_PATH"

EXISTING_API_KEY="${CODEX_API_KEY:-}"
if [ "$NON_INTERACTIVE" -eq 1 ]; then
    ENDPOINT="$DEFAULT_ENDPOINT"
    API_KEY="$(read_api_key "$EXISTING_API_KEY")"
    MODEL="$DEFAULT_MODEL"
    EFFORT="$DEFAULT_EFFORT"
else
    ENDPOINT="$(read_with_default 'Endpoint' "$DEFAULT_ENDPOINT")"
    API_KEY="$(read_api_key "$EXISTING_API_KEY")"
    MODEL="$(read_with_default 'Model' "$DEFAULT_MODEL")"
    EFFORT="$(read_with_default 'Reasoning effort' "$DEFAULT_EFFORT")"
fi

case "$ENDPOINT" in
    http://*|https://*)
        ;;
    *)
        die 'Endpoint must be an absolute HTTP or HTTPS URL.'
        ;;
esac
case "$ENDPOINT" in
    *[[:space:]]*)
        die 'Endpoint cannot contain whitespace.'
        ;;
esac
case "$API_KEY" in
    *$'\n'*|*$'\r'*)
        die 'API key cannot contain a newline.'
        ;;
esac
[ -n "$MODEL" ] || die 'Model cannot be empty.'
[ -n "$EFFORT" ] || die 'Reasoning effort cannot be empty.'

mkdir -p "$CODEX_HOME_PATH"

if [ -f "$STATE_PATH" ]; then
    [ "$(state_get schema_version)" = '1' ] || die "Unsupported install state: $STATE_PATH"
    [ -d "$BACKUP_DIRECTORY" ] || die "Backup directory is missing: $BACKUP_DIRECTORY"
    CONFIG_EXISTED="$(state_get config_existed)"
    CATALOG_EXISTED="$(state_get catalog_existed)"
    ENV_FILE_EXISTED="$(state_get env_file_existed)"
    SHELL_PROFILE_EXISTED="$(state_get shell_profile_existed)"
    SHELL_PROFILE_PATH="$(state_get shell_profile_path)"
else
    SHELL_PROFILE_PATH="$(choose_shell_profile)"
    case "$SHELL_PROFILE_PATH" in
        *$'\n'*)
            die 'Shell profile path contains a newline.'
            ;;
    esac
    if [ -f "$SHELL_PROFILE_PATH" ] && grep -Fq "$PROFILE_BEGIN" "$SHELL_PROFILE_PATH"; then
        die "A managed Codex endpoint block already exists in $SHELL_PROFILE_PATH but no install state was found."
    fi

    mkdir "$BACKUP_DIRECTORY"
    chmod 700 "$BACKUP_DIRECTORY"

    CONFIG_EXISTED=0
    if [ -f "$CONFIG_PATH" ]; then
        CONFIG_EXISTED=1
        cp -p "$CONFIG_PATH" "$BACKUP_DIRECTORY/config.toml.original"
    fi

    CATALOG_EXISTED=0
    if [ -f "$TARGET_CATALOG_PATH" ]; then
        CATALOG_EXISTED=1
        cp -p "$TARGET_CATALOG_PATH" "$BACKUP_DIRECTORY/$TARGET_CATALOG_NAME.original"
    fi

    ENV_FILE_EXISTED=0
    if [ -f "$ENV_FILE_PATH" ]; then
        ENV_FILE_EXISTED=1
        cp -p "$ENV_FILE_PATH" "$BACKUP_DIRECTORY/$ENV_FILE_NAME.original"
    fi

    SHELL_PROFILE_EXISTED=0
    if [ -f "$SHELL_PROFILE_PATH" ]; then
        SHELL_PROFILE_EXISTED=1
    fi

    INSTALLED_CONFIG_SHA256=''
    INSTALLED_CATALOG_SHA256=''
    INSTALLED_ENV_SHA256=''
    write_state
fi

write_config

catalog_temporary_path="$(mktemp "$CODEX_HOME_PATH/.catalog.XXXXXX")"
cp "$CATALOG_SOURCE_PATH" "$catalog_temporary_path"
mv -f "$catalog_temporary_path" "$TARGET_CATALOG_PATH"

write_environment_file
write_shell_profile_block

export CODEX_BASE_URL="$ENDPOINT"
export CODEX_API_KEY="$API_KEY"
export CODEX_MODEL="$MODEL"
export CODEX_REASONING_EFFORT="$EFFORT"

INSTALLED_CONFIG_SHA256="$(sha256_file "$CONFIG_PATH")"
INSTALLED_CATALOG_SHA256="$(sha256_file "$TARGET_CATALOG_PATH")"
INSTALLED_ENV_SHA256="$(sha256_file "$ENV_FILE_PATH")"
write_state

printf '\nCodex custom endpoint installation completed.\n'
printf 'Config:  %s\n' "$CONFIG_PATH"
printf 'Catalog: %s\n' "$TARGET_CATALOG_PATH"
printf 'Environment file: %s\n' "$ENV_FILE_PATH"
printf 'Shell profile: %s\n' "$SHELL_PROFILE_PATH"
printf 'Open a new terminal or run: source %s\n' "$(shell_quote "$ENV_FILE_PATH")"
printf 'Restart Codex after loading the new environment.\n'
