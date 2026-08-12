#!/usr/bin/env bash
set -euo pipefail

DEFAULT_ENDPOINT='https://codex.finnvnoi.top/backend-api/codex'
DEFAULT_MODEL='gpt-5.6-sol'
DEFAULT_EFFORT='xhigh'
DEFAULT_SHOW_QUOTA=1
DEFAULT_QUOTA_PROXY_PORT=48123
PROVIDER_ID='codex'
PROVIDER_NAME='openai'
API_KEY_VARIABLE='CODEX_API_KEY'
TARGET_CATALOG_NAME='legacy_direct_model_catalog.json'
QUOTA_PROXY_NAME='codex_quota_proxy.py'
QUOTA_LAUNCHER_NAME='codex_quota_proxy_start.sh'
QUOTA_DESKTOP_NAME='codex-quota-proxy.desktop'
QUOTA_LAUNCH_AGENT_NAME='com.finnvnoi.codex-quota-proxy.plist'
STATE_FILE_NAME='codex_custom_endpoint_unix_state'
BACKUP_DIRECTORY_NAME='codex_custom_endpoint_unix_backup'
ENV_FILE_NAME='codex_custom_endpoint.env'
PROFILE_BEGIN='# >>> codex-custom-endpoint >>>'
PROFILE_END='# <<< codex-custom-endpoint <<<'
NON_INTERACTIVE=0
DOCTOR_MODE=0

die() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

usage() {
    printf '%s\n' \
        'Usage: ./codex_install.sh [--non-interactive | --doctor]' \
        '' \
        'Without arguments, the installer prompts for endpoint, API key, model, effort, and quota display.' \
        '--non-interactive uses the bundled defaults, enables quota display, and requires CODEX_API_KEY to be set.' \
        '--doctor checks the saved config and API key loading without printing the key.'
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --non-interactive)
            NON_INTERACTIVE=1
            ;;
        --doctor)
            DOCTOR_MODE=1
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
BUNDLED_QUOTA_PROXY_PATH="$SCRIPT_DIRECTORY/$QUOTA_PROXY_NAME"
LEGACY_FALLBACK_PATH="$CODEX_HOME_PATH/legacy-direct-model-catalog.json"
TARGET_QUOTA_PROXY_PATH="$CODEX_HOME_PATH/$QUOTA_PROXY_NAME"
QUOTA_LAUNCHER_PATH="$CODEX_HOME_PATH/$QUOTA_LAUNCHER_NAME"
if [ "$(uname -s)" = 'Darwin' ]; then
    QUOTA_AUTOSTART_PATH="$HOME/Library/LaunchAgents/$QUOTA_LAUNCH_AGENT_NAME"
    QUOTA_AUTOSTART_KIND='launchd'
else
    QUOTA_AUTOSTART_PATH="${XDG_CONFIG_HOME:-$HOME/.config}/autostart/$QUOTA_DESKTOP_NAME"
    QUOTA_AUTOSTART_KIND='xdg'
fi

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
        fish)
            printf '%s\n' "$HOME/.config/fish/conf.d/codex-custom-endpoint.fish"
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

xml_escape() {
    printf '%s' "$1" | sed \
        -e 's/&/\&amp;/g' \
        -e 's/</\&lt;/g' \
        -e 's/>/\&gt;/g' \
        -e 's/"/\&quot;/g' \
        -e "s/'/\&apos;/g"
}

trim_api_key() {
    printf '%s' "$1" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
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
    existing_value="$(trim_api_key "$1")"
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

    entered_value="$(trim_api_key "$entered_value")"
    if [ -z "$entered_value" ]; then
        [ -n "$existing_value" ] || die 'API key cannot be empty because CODEX_API_KEY is not set.'
        printf '%s\n' "$existing_value"
    else
        printf '%s\n' "$entered_value"
    fi
}

read_yes_no() {
    label="$1"
    default_value="$2"
    if [ "$default_value" = '1' ]; then
        prompt='Y/n'
    else
        prompt='y/N'
    fi
    while :; do
        printf '%s [%s]: ' "$label" "$prompt" >&2
        if ! IFS= read -r entered_value; then
            die "Could not read $label."
        fi
        case "$entered_value" in
            '')
                printf '%s\n' "$default_value"
                return
                ;;
            y|Y|yes|YES|Yes)
                printf '1\n'
                return
                ;;
            n|N|no|NO|No)
                printf '0\n'
                return
                ;;
            *)
                printf 'Please enter y or n.\n' >&2
                ;;
        esac
    done
}

get_python_executable() {
    for candidate in python3 python; do
        if command -v "$candidate" >/dev/null 2>&1; then
            "$candidate" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 8) else 1)' >/dev/null 2>&1 ||
                continue
            command -v "$candidate"
            return
        fi
    done
    die 'Python 3.8 or newer is required when Show quota is enabled.'
}

derive_quota_url() {
    "$PYTHON_EXECUTABLE" "$BUNDLED_QUOTA_PROXY_PATH" --derive-quota-url "$1"
}

find_quota_proxy_port() {
    CODEX_QUOTA_PROXY_PORT="$DEFAULT_QUOTA_PROXY_PORT" \
        "$PYTHON_EXECUTABLE" "$BUNDLED_QUOTA_PROXY_PATH" --find-port
}

local_quota_proxy_base_url() {
    CODEX_QUOTA_PROXY_PORT="$2" \
        "$PYTHON_EXECUTABLE" "$BUNDLED_QUOTA_PROXY_PATH" --local-base-url "$1"
}

generate_proxy_token() {
    "$PYTHON_EXECUTABLE" -c 'import secrets; print(secrets.token_hex(32))'
}

stop_existing_quota_proxy() {
    [ -f "$TARGET_QUOTA_PROXY_PATH" ] || return 0
    [ -f "$QUOTA_LAUNCHER_PATH" ] || return 0
    "$QUOTA_LAUNCHER_PATH" --stop >/dev/null 2>&1 || true
}

write_quota_launcher() {
    launcher_temporary_path="$(mktemp "$CODEX_HOME_PATH/.codex-quota-launcher.XXXXXX")"
    {
        printf '%s\n' '#!/bin/sh' 'set -eu'
        printf 'export CODEX_UPSTREAM_BASE_URL=%s\n' "$(shell_quote "$ENDPOINT")"
        printf 'export CODEX_QUOTA_URL=%s\n' "$(shell_quote "$QUOTA_URL")"
        printf 'export CODEX_API_KEY=%s\n' "$(shell_quote "$API_KEY")"
        printf 'export CODEX_QUOTA_PROXY_TOKEN=%s\n' "$(shell_quote "$QUOTA_PROXY_TOKEN")"
        printf 'export CODEX_QUOTA_PROXY_HOST=%s\n' "$(shell_quote '127.0.0.1')"
        printf 'export CODEX_QUOTA_PROXY_PORT=%s\n' "$(shell_quote "$QUOTA_PROXY_PORT")"
        printf 'exec %s %s "${1:---ensure-running}"\n' \
            "$(shell_quote "$PYTHON_EXECUTABLE")" \
            "$(shell_quote "$TARGET_QUOTA_PROXY_PATH")"
    } > "$launcher_temporary_path"
    chmod 700 "$launcher_temporary_path"
    mv -f "$launcher_temporary_path" "$QUOTA_LAUNCHER_PATH"
}

write_quota_autostart() {
    mkdir -p "$(dirname "$QUOTA_AUTOSTART_PATH")"
    autostart_temporary_path="$(mktemp "${TMPDIR:-/tmp}/codex-quota-autostart.XXXXXX")"
    if [ "$QUOTA_AUTOSTART_KIND" = 'launchd' ]; then
        escaped_launcher_path="$(xml_escape "$QUOTA_LAUNCHER_PATH")"
        {
            printf '%s\n' \
                '<?xml version="1.0" encoding="UTF-8"?>' \
                '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
                '<plist version="1.0">' \
                '<dict>' \
                '  <key>Label</key>' \
                '  <string>com.finnvnoi.codex-quota-proxy</string>' \
                '  <key>ProgramArguments</key>' \
                '  <array>' \
                "    <string>$escaped_launcher_path</string>" \
                '    <string>--ensure-running</string>' \
                '  </array>' \
                '  <key>RunAtLoad</key>' \
                '  <true/>' \
                '</dict>' \
                '</plist>'
        } > "$autostart_temporary_path"
    else
        {
            printf '%s\n' \
                '[Desktop Entry]' \
                'Type=Application' \
                'Name=Codex quota proxy' \
                "Exec=\"$QUOTA_LAUNCHER_PATH\" --ensure-running" \
                'Terminal=false' \
                'NoDisplay=true' \
                'X-GNOME-Autostart-enabled=true'
        } > "$autostart_temporary_path"
    fi
    chmod 600 "$autostart_temporary_path"
    mv -f "$autostart_temporary_path" "$QUOTA_AUTOSTART_PATH"
}

start_quota_proxy() {
    "$QUOTA_LAUNCHER_PATH" --ensure-running
    "$QUOTA_LAUNCHER_PATH" --check >/dev/null
}

remove_shell_profile_block() {
    profile_path="$1"
    profile_existed="$2"
    [ -f "$profile_path" ] || return 0

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

config_has_tui_status_line() {
    [ -f "$CONFIG_PATH" ] || return 1
    LC_ALL=C awk '
        /^[[:space:]]*\[/ {
            in_tui = $0 ~ /^[[:space:]]*\[[[:space:]]*tui[[:space:]]*\][[:space:]]*(#.*)?$/
            next
        }
        in_tui && /^[[:space:]]*status_line[[:space:]]*=/ {
            found = 1
            exit
        }
        END {
            exit found ? 0 : 1
        }
    ' "$CONFIG_PATH"
}

write_state() {
    state_temporary_path="$(mktemp "$CODEX_HOME_PATH/.codex-state.XXXXXX")"
    {
        printf 'schema_version=2\n'
        printf 'config_existed=%s\n' "$CONFIG_EXISTED"
        printf 'catalog_existed=%s\n' "$CATALOG_EXISTED"
        printf 'env_file_existed=%s\n' "$ENV_FILE_EXISTED"
        printf 'shell_profile_existed=%s\n' "$SHELL_PROFILE_EXISTED"
        printf 'shell_profile_path=%s\n' "$SHELL_PROFILE_PATH"
        printf 'quota_proxy_existed=%s\n' "$QUOTA_PROXY_EXISTED"
        printf 'quota_launcher_existed=%s\n' "$QUOTA_LAUNCHER_EXISTED"
        printf 'quota_autostart_existed=%s\n' "$QUOTA_AUTOSTART_EXISTED"
        printf 'quota_autostart_path=%s\n' "$QUOTA_AUTOSTART_PATH"
        printf 'managed_status_line_owned=%s\n' "$MANAGED_STATUS_LINE_OWNED"
        printf 'installed_config_sha256=%s\n' "$INSTALLED_CONFIG_SHA256"
        printf 'installed_catalog_sha256=%s\n' "$INSTALLED_CATALOG_SHA256"
        printf 'installed_env_sha256=%s\n' "$INSTALLED_ENV_SHA256"
        printf 'installed_quota_proxy_sha256=%s\n' "$INSTALLED_QUOTA_PROXY_SHA256"
        printf 'installed_quota_launcher_sha256=%s\n' "$INSTALLED_QUOTA_LAUNCHER_SHA256"
        printf 'installed_quota_autostart_sha256=%s\n' "$INSTALLED_QUOTA_AUTOSTART_SHA256"
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
    provider_url_line="base_url = $(toml_quote "$CONFIGURED_ENDPOINT")"
    if [ "$SHOW_QUOTA" = '1' ]; then
        provider_auth_line="experimental_bearer_token = $(toml_quote "$QUOTA_PROXY_TOKEN")"
    else
        provider_auth_line="env_key = $(toml_quote "$API_KEY_VARIABLE")"
    fi
    provider_wire_line="wire_api = $(toml_quote 'responses')"
    provider_websocket_line='supports_websockets = false'
    provider_auth_requirement_line='requires_openai_auth = true'
    tui_status_line='status_line = ["model-with-reasoning", "five-hour-limit", "weekly-limit"]'
    config_input="$CONFIG_PATH"
    [ -f "$config_input" ] || config_input='/dev/null'
    config_temporary_path="$(mktemp "$CODEX_HOME_PATH/.config.toml.XXXXXX")"

    MODEL_LINE="$model_line" \
    PROVIDER_LINE="$provider_line" \
    EFFORT_LINE="$effort_line" \
    CATALOG_LINE="$catalog_line" \
    PROVIDER_NAME_LINE="$provider_name_line" \
    PROVIDER_URL_LINE="$provider_url_line" \
    PROVIDER_AUTH_LINE="$provider_auth_line" \
    PROVIDER_WIRE_LINE="$provider_wire_line" \
    PROVIDER_WEBSOCKET_LINE="$provider_websocket_line" \
    PROVIDER_AUTH_REQUIREMENT_LINE="$provider_auth_requirement_line" \
    TUI_STATUS_LINE="$tui_status_line" \
    SHOW_QUOTA="$SHOW_QUOTA" \
    MANAGED_STATUS_LINE_OWNED="$MANAGED_STATUS_LINE_OWNED" \
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
            if (!seen_provider_auth) print ENVIRON["PROVIDER_AUTH_LINE"]
            if (!seen_provider_wire) print ENVIRON["PROVIDER_WIRE_LINE"]
            if (!seen_provider_websocket) print ENVIRON["PROVIDER_WEBSOCKET_LINE"]
            if (!seen_provider_auth_requirement) print ENVIRON["PROVIDER_AUTH_REQUIREMENT_LINE"]
        }
        function emit_missing_tui() {
            if (ENVIRON["SHOW_QUOTA"] == "1" && !seen_tui_status) {
                print ENVIRON["TUI_STATUS_LINE"]
            }
        }
        BEGIN {
            top_finished = 0
            in_provider = 0
            in_tui = 0
            provider_seen = 0
            tui_seen = 0
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
                if (in_tui) {
                    emit_missing_tui()
                    in_tui = 0
                }
                if (line ~ /^[[:space:]]*\[[[:space:]]*model_providers\.codex[[:space:]]*\][[:space:]]*(#.*)?$/) {
                    provider_seen = 1
                    in_provider = 1
                }
                if (line ~ /^[[:space:]]*\[[[:space:]]*tui[[:space:]]*\][[:space:]]*(#.*)?$/) {
                    tui_seen = 1
                    in_tui = 1
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
                if (line ~ /^[[:space:]]*(env_key|experimental_bearer_token)[[:space:]]*=/) {
                    if (!seen_provider_auth) print ENVIRON["PROVIDER_AUTH_LINE"]
                    seen_provider_auth = 1
                    next
                }
                if (line ~ /^[[:space:]]*wire_api[[:space:]]*=/) {
                    if (!seen_provider_wire) print ENVIRON["PROVIDER_WIRE_LINE"]
                    seen_provider_wire = 1
                    next
                }
                if (line ~ /^[[:space:]]*supports_websockets[[:space:]]*=/) {
                    if (!seen_provider_websocket) print ENVIRON["PROVIDER_WEBSOCKET_LINE"]
                    seen_provider_websocket = 1
                    next
                }
                if (line ~ /^[[:space:]]*requires_openai_auth[[:space:]]*=/) {
                    if (!seen_provider_auth_requirement) print ENVIRON["PROVIDER_AUTH_REQUIREMENT_LINE"]
                    seen_provider_auth_requirement = 1
                    next
                }
            }

            if (in_tui && line ~ /^[[:space:]]*status_line[[:space:]]*=/) {
                if (ENVIRON["SHOW_QUOTA"] != "1" &&
                    ENVIRON["MANAGED_STATUS_LINE_OWNED"] == "1" &&
                    line == ENVIRON["TUI_STATUS_LINE"]) {
                    seen_tui_status = 1
                    next
                }
                print line
                seen_tui_status = 1
                next
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
                print ENVIRON["PROVIDER_AUTH_LINE"]
                print ENVIRON["PROVIDER_WIRE_LINE"]
                print ENVIRON["PROVIDER_WEBSOCKET_LINE"]
                print ENVIRON["PROVIDER_AUTH_REQUIREMENT_LINE"]
            }
            if (in_tui) {
                emit_missing_tui()
            } else if (ENVIRON["SHOW_QUOTA"] == "1" && !tui_seen) {
                print ""
                print "[tui]"
                print ENVIRON["TUI_STATUS_LINE"]
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

    case "$SHELL_PROFILE_PATH" in
        *.fish)
            {
                printf '%s\n' "$PROFILE_BEGIN"
                printf 'set -gx CODEX_BASE_URL %s\n' "$(shell_quote "$ENDPOINT")"
                printf 'set -gx CODEX_API_KEY %s\n' "$(shell_quote "$API_KEY")"
                printf 'set -gx CODEX_MODEL %s\n' "$(shell_quote "$MODEL")"
                printf 'set -gx CODEX_REASONING_EFFORT %s\n' "$(shell_quote "$EFFORT")"
                if [ "$SHOW_QUOTA" = '1' ]; then
                    printf 'if test -x %s\n' "$(shell_quote "$QUOTA_LAUNCHER_PATH")"
                    printf '    %s --ensure-running >/dev/null 2>&1\n' "$(shell_quote "$QUOTA_LAUNCHER_PATH")"
                    printf 'end\n'
                fi
                printf '%s\n' "$PROFILE_END"
            } >> "$profile_temporary_path"
            ;;
        *)
            {
                printf '%s\n' "$PROFILE_BEGIN"
                printf '[ -f %s ] && . %s\n' "$(shell_quote "$ENV_FILE_PATH")" "$(shell_quote "$ENV_FILE_PATH")"
                if [ "$SHOW_QUOTA" = '1' ]; then
                    printf '[ -x %s ] && %s --ensure-running >/dev/null 2>&1 || true\n' \
                        "$(shell_quote "$QUOTA_LAUNCHER_PATH")" \
                        "$(shell_quote "$QUOTA_LAUNCHER_PATH")"
                fi
                printf '%s\n' "$PROFILE_END"
            } >> "$profile_temporary_path"
            ;;
    esac

    if [ -f "$SHELL_PROFILE_PATH" ]; then
        cp "$profile_temporary_path" "$SHELL_PROFILE_PATH"
        rm -f "$profile_temporary_path"
    else
        mv -f "$profile_temporary_path" "$SHELL_PROFILE_PATH"
    fi
    case "$SHELL_PROFILE_PATH" in
        *.fish)
            chmod 600 "$SHELL_PROFILE_PATH"
            ;;
    esac
}

run_doctor() {
    current_api_key="$(trim_api_key "${CODEX_API_KEY:-}")"
    desired_profile_path="$(choose_shell_profile)"
    if [ -f "$STATE_PATH" ]; then
        doctor_profile_path="$(state_get shell_profile_path)"
    else
        doctor_profile_path="$desired_profile_path"
    fi

    printf 'Shell: %s\n' "${SHELL:-unknown}"
    printf 'Expected shell profile: %s\n' "$doctor_profile_path"

    doctor_ok=1
    if [ -f "$ENV_FILE_PATH" ]; then
        saved_api_key="$(
            unset CODEX_BASE_URL CODEX_API_KEY CODEX_MODEL CODEX_REASONING_EFFORT
            . "$ENV_FILE_PATH"
            printf '%s' "${CODEX_API_KEY:-}"
        )"
        saved_api_key="$(trim_api_key "$saved_api_key")"
        printf 'Saved API key: loaded (%s characters; value hidden)\n' "${#saved_api_key}"
        if [ -z "$saved_api_key" ]; then
            doctor_ok=0
        fi
    else
        saved_api_key=''
        printf 'Saved API key: missing environment file\n'
        doctor_ok=0
    fi

    if [ -n "$current_api_key" ]; then
        printf 'Current terminal API key: loaded (%s characters; value hidden)\n' "${#current_api_key}"
    else
        printf 'Current terminal API key: not loaded\n'
        doctor_ok=0
    fi

    if [ -n "$saved_api_key" ] && [ -n "$current_api_key" ]; then
        if [ "$saved_api_key" = "$current_api_key" ]; then
            printf 'Current key matches saved key: yes\n'
        else
            printf 'Current key matches saved key: no\n'
            doctor_ok=0
        fi
    fi

    if [ -f "$doctor_profile_path" ] && grep -Fq "$PROFILE_BEGIN" "$doctor_profile_path"; then
        printf 'Automatic shell loading: configured\n'
    else
        printf 'Automatic shell loading: missing\n'
        doctor_ok=0
    fi
    if [ "$doctor_profile_path" != "$desired_profile_path" ]; then
        printf 'Shell profile migration needed: %s\n' "$desired_profile_path"
        doctor_ok=0
    fi

    if [ -f "$CONFIG_PATH" ] &&
        grep -Eq '^[[:space:]]*model_provider[[:space:]]*=[[:space:]]*"codex"' "$CONFIG_PATH" &&
        grep -Eq '^[[:space:]]*(env_key|experimental_bearer_token)[[:space:]]*=' "$CONFIG_PATH"; then
        printf 'Codex provider config: configured\n'
    else
        printf 'Codex provider config: missing or inconsistent\n'
        doctor_ok=0
    fi

    if [ -f "$QUOTA_LAUNCHER_PATH" ]; then
        if "$QUOTA_LAUNCHER_PATH" --check >/dev/null 2>&1; then
            printf 'Quota proxy: running\n'
        else
            printf 'Quota proxy: configured but not running\n'
            doctor_ok=0
        fi
    else
        printf 'Quota proxy: disabled\n'
    fi

    if [ "$doctor_ok" -eq 1 ]; then
        printf 'Diagnosis: environment and Codex config are aligned.\n'
        printf 'If the endpoint still reports invalid_api_key, rerun the installer and enter a valid key instead of keeping the existing one.\n'
        return 0
    fi

    printf 'Diagnosis: rerun the installer, then open a new terminal or source %s once.\n' "$(shell_quote "$ENV_FILE_PATH")"
    return 1
}

if [ "$DOCTOR_MODE" -eq 1 ]; then
    if run_doctor; then
        exit 0
    fi
    exit 1
fi

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
    SHOW_QUOTA="$DEFAULT_SHOW_QUOTA"
else
    ENDPOINT="$(read_with_default 'Endpoint' "$DEFAULT_ENDPOINT")"
    API_KEY="$(read_api_key "$EXISTING_API_KEY")"
    MODEL="$(read_with_default 'Model' "$DEFAULT_MODEL")"
    EFFORT="$(read_with_default 'Reasoning effort' "$DEFAULT_EFFORT")"
    SHOW_QUOTA="$(read_yes_no 'Show quota in Codex CLI and Codex App' "$DEFAULT_SHOW_QUOTA")"
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
stop_existing_quota_proxy

CONFIGURED_ENDPOINT="$ENDPOINT"
PYTHON_EXECUTABLE=''
QUOTA_URL=''
QUOTA_PROXY_PORT=''
QUOTA_PROXY_TOKEN=''
if [ "$SHOW_QUOTA" = '1' ]; then
    [ -f "$BUNDLED_QUOTA_PROXY_PATH" ] || die "Missing $QUOTA_PROXY_NAME beside the installer."
    PYTHON_EXECUTABLE="$(get_python_executable)"
    DEFAULT_QUOTA_URL="$(derive_quota_url "$ENDPOINT")"
    if [ "$NON_INTERACTIVE" -eq 1 ]; then
        QUOTA_URL="$DEFAULT_QUOTA_URL"
    else
        QUOTA_URL="$(read_with_default 'Quota endpoint' "$DEFAULT_QUOTA_URL")"
    fi
    case "$QUOTA_URL" in
        http://*|https://*)
            ;;
        *)
            die 'Quota endpoint must be an absolute HTTP or HTTPS URL.'
            ;;
    esac
    case "$QUOTA_URL" in
        *[[:space:]]*)
            die 'Quota endpoint cannot contain whitespace.'
            ;;
    esac
    QUOTA_PROXY_PORT="$(find_quota_proxy_port)"
    QUOTA_PROXY_TOKEN="$(generate_proxy_token)"
    CONFIGURED_ENDPOINT="$(local_quota_proxy_base_url "$ENDPOINT" "$QUOTA_PROXY_PORT")"
fi

if [ -f "$STATE_PATH" ]; then
    STATE_SCHEMA_VERSION="$(state_get schema_version)"
    [ "$STATE_SCHEMA_VERSION" = '1' ] || [ "$STATE_SCHEMA_VERSION" = '2' ] ||
        die "Unsupported install state: $STATE_PATH"
    [ -d "$BACKUP_DIRECTORY" ] || die "Backup directory is missing: $BACKUP_DIRECTORY"
    CONFIG_EXISTED="$(state_get config_existed)"
    CATALOG_EXISTED="$(state_get catalog_existed)"
    ENV_FILE_EXISTED="$(state_get env_file_existed)"
    SHELL_PROFILE_EXISTED="$(state_get shell_profile_existed)"
    SHELL_PROFILE_PATH="$(state_get shell_profile_path)"
    if [ "$STATE_SCHEMA_VERSION" = '2' ]; then
        QUOTA_PROXY_EXISTED="$(state_get quota_proxy_existed)"
        QUOTA_LAUNCHER_EXISTED="$(state_get quota_launcher_existed)"
        QUOTA_AUTOSTART_EXISTED="$(state_get quota_autostart_existed)"
        SAVED_QUOTA_AUTOSTART_PATH="$(state_get quota_autostart_path)"
        if [ -n "$SAVED_QUOTA_AUTOSTART_PATH" ] && [ "$SAVED_QUOTA_AUTOSTART_PATH" != "$QUOTA_AUTOSTART_PATH" ]; then
            die "Quota autostart location changed: $SAVED_QUOTA_AUTOSTART_PATH"
        fi
        MANAGED_STATUS_LINE_OWNED="$(state_get managed_status_line_owned)"
        [ -n "$MANAGED_STATUS_LINE_OWNED" ] || MANAGED_STATUS_LINE_OWNED=0
    else
        QUOTA_PROXY_EXISTED=0
        QUOTA_LAUNCHER_EXISTED=0
        QUOTA_AUTOSTART_EXISTED=0
        MANAGED_STATUS_LINE_OWNED=0
        if [ -f "$TARGET_QUOTA_PROXY_PATH" ]; then
            QUOTA_PROXY_EXISTED=1
            cp -p "$TARGET_QUOTA_PROXY_PATH" "$BACKUP_DIRECTORY/$QUOTA_PROXY_NAME.original"
        fi
        if [ -f "$QUOTA_LAUNCHER_PATH" ]; then
            QUOTA_LAUNCHER_EXISTED=1
            cp -p "$QUOTA_LAUNCHER_PATH" "$BACKUP_DIRECTORY/$QUOTA_LAUNCHER_NAME.original"
        fi
        if [ -f "$QUOTA_AUTOSTART_PATH" ]; then
            QUOTA_AUTOSTART_EXISTED=1
            cp -p "$QUOTA_AUTOSTART_PATH" "$BACKUP_DIRECTORY/$(basename "$QUOTA_AUTOSTART_PATH").original"
        fi
    fi
    DESIRED_SHELL_PROFILE_PATH="$(choose_shell_profile)"
    if [ "$SHELL_PROFILE_PATH" != "$DESIRED_SHELL_PROFILE_PATH" ]; then
        if [ -f "$DESIRED_SHELL_PROFILE_PATH" ] && grep -Fq "$PROFILE_BEGIN" "$DESIRED_SHELL_PROFILE_PATH"; then
            die "A managed Codex endpoint block already exists in $DESIRED_SHELL_PROFILE_PATH."
        fi
        remove_shell_profile_block "$SHELL_PROFILE_PATH" "$SHELL_PROFILE_EXISTED"
        SHELL_PROFILE_PATH="$DESIRED_SHELL_PROFILE_PATH"
        SHELL_PROFILE_EXISTED=0
        if [ -f "$SHELL_PROFILE_PATH" ]; then
            SHELL_PROFILE_EXISTED=1
        fi
    fi
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

    QUOTA_PROXY_EXISTED=0
    if [ -f "$TARGET_QUOTA_PROXY_PATH" ]; then
        QUOTA_PROXY_EXISTED=1
        cp -p "$TARGET_QUOTA_PROXY_PATH" "$BACKUP_DIRECTORY/$QUOTA_PROXY_NAME.original"
    fi

    QUOTA_LAUNCHER_EXISTED=0
    if [ -f "$QUOTA_LAUNCHER_PATH" ]; then
        QUOTA_LAUNCHER_EXISTED=1
        cp -p "$QUOTA_LAUNCHER_PATH" "$BACKUP_DIRECTORY/$QUOTA_LAUNCHER_NAME.original"
    fi

    QUOTA_AUTOSTART_EXISTED=0
    if [ -f "$QUOTA_AUTOSTART_PATH" ]; then
        QUOTA_AUTOSTART_EXISTED=1
        cp -p "$QUOTA_AUTOSTART_PATH" "$BACKUP_DIRECTORY/$(basename "$QUOTA_AUTOSTART_PATH").original"
    fi

    SHELL_PROFILE_EXISTED=0
    if [ -f "$SHELL_PROFILE_PATH" ]; then
        SHELL_PROFILE_EXISTED=1
    fi

    INSTALLED_CONFIG_SHA256=''
    INSTALLED_CATALOG_SHA256=''
    INSTALLED_ENV_SHA256=''
    INSTALLED_QUOTA_PROXY_SHA256=''
    INSTALLED_QUOTA_LAUNCHER_SHA256=''
    INSTALLED_QUOTA_AUTOSTART_SHA256=''
    MANAGED_STATUS_LINE_OWNED=0
    write_state
fi

if [ "$SHOW_QUOTA" = '1' ] && ! config_has_tui_status_line; then
    MANAGED_STATUS_LINE_OWNED=1
fi
write_config
if [ "$SHOW_QUOTA" != '1' ]; then
    MANAGED_STATUS_LINE_OWNED=0
fi

catalog_temporary_path="$(mktemp "$CODEX_HOME_PATH/.catalog.XXXXXX")"
cp "$CATALOG_SOURCE_PATH" "$catalog_temporary_path"
mv -f "$catalog_temporary_path" "$TARGET_CATALOG_PATH"

if [ "$SHOW_QUOTA" = '1' ]; then
    cp "$BUNDLED_QUOTA_PROXY_PATH" "$TARGET_QUOTA_PROXY_PATH"
    chmod 700 "$TARGET_QUOTA_PROXY_PATH"
    write_quota_launcher
    write_quota_autostart
    start_quota_proxy
else
    if [ "$QUOTA_PROXY_EXISTED" = '1' ]; then
        cp -p "$BACKUP_DIRECTORY/$QUOTA_PROXY_NAME.original" "$TARGET_QUOTA_PROXY_PATH"
    else
        rm -f "$TARGET_QUOTA_PROXY_PATH"
    fi
    if [ "$QUOTA_LAUNCHER_EXISTED" = '1' ]; then
        cp -p "$BACKUP_DIRECTORY/$QUOTA_LAUNCHER_NAME.original" "$QUOTA_LAUNCHER_PATH"
    else
        rm -f "$QUOTA_LAUNCHER_PATH"
    fi
    if [ "$QUOTA_AUTOSTART_EXISTED" = '1' ]; then
        mkdir -p "$(dirname "$QUOTA_AUTOSTART_PATH")"
        cp -p "$BACKUP_DIRECTORY/$(basename "$QUOTA_AUTOSTART_PATH").original" "$QUOTA_AUTOSTART_PATH"
    else
        rm -f "$QUOTA_AUTOSTART_PATH"
    fi
fi

write_environment_file
write_shell_profile_block

export CODEX_BASE_URL="$ENDPOINT"
export CODEX_API_KEY="$API_KEY"
export CODEX_MODEL="$MODEL"
export CODEX_REASONING_EFFORT="$EFFORT"

INSTALLED_CONFIG_SHA256="$(sha256_file "$CONFIG_PATH")"
INSTALLED_CATALOG_SHA256="$(sha256_file "$TARGET_CATALOG_PATH")"
INSTALLED_ENV_SHA256="$(sha256_file "$ENV_FILE_PATH")"
if [ -f "$TARGET_QUOTA_PROXY_PATH" ]; then
    INSTALLED_QUOTA_PROXY_SHA256="$(sha256_file "$TARGET_QUOTA_PROXY_PATH")"
else
    INSTALLED_QUOTA_PROXY_SHA256=''
fi
if [ -f "$QUOTA_LAUNCHER_PATH" ]; then
    INSTALLED_QUOTA_LAUNCHER_SHA256="$(sha256_file "$QUOTA_LAUNCHER_PATH")"
else
    INSTALLED_QUOTA_LAUNCHER_SHA256=''
fi
if [ -f "$QUOTA_AUTOSTART_PATH" ]; then
    INSTALLED_QUOTA_AUTOSTART_SHA256="$(sha256_file "$QUOTA_AUTOSTART_PATH")"
else
    INSTALLED_QUOTA_AUTOSTART_SHA256=''
fi
write_state

printf '\nCodex custom endpoint installation completed.\n'
printf 'Config:  %s\n' "$CONFIG_PATH"
printf 'Catalog: %s\n' "$TARGET_CATALOG_PATH"
if [ "$SHOW_QUOTA" = '1' ]; then
    printf 'Quota:   enabled via %s\n' "$QUOTA_URL"
    printf 'Proxy:   %s\n' "$CONFIGURED_ENDPOINT"
    printf 'Autostart: %s\n' "$QUOTA_AUTOSTART_PATH"
else
    printf 'Quota:   disabled\n'
fi
printf 'Environment file: %s\n' "$ENV_FILE_PATH"
printf 'Shell profile: %s\n' "$SHELL_PROFILE_PATH"
printf 'API key stored: %s characters (value hidden)\n' "${#API_KEY}"
printf 'Every new terminal will load these variables automatically.\n'
case "$SHELL_PROFILE_PATH" in
    *.fish)
        printf 'For this already-open Fish terminal only, run once: source %s\n' "$(shell_quote "$SHELL_PROFILE_PATH")"
        ;;
    *)
        printf 'For this already-open terminal only, run once: source %s\n' "$(shell_quote "$ENV_FILE_PATH")"
        ;;
esac
printf 'If authentication fails, run: %s --doctor\n' "$(shell_quote "$0")"
printf 'Restart Codex after loading the new environment.\n'
