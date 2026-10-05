#!/usr/bin/env bash
# Prepare native extension policies without starting browsers or copying profiles.

browser_extension_policy_file_is_safe() {
    local path="$1" mode
    [[ -f "$path" && ! -L "$path" && "$(readlink -m -- "$path")" == "$path" &&
       "$(stat -c %h -- "$path")" == 1 ]] || return 1
    mode="$(stat -c %a -- "$path")"
    (( (8#$mode & 8#022) == 0 ))
}

browser_extension_policy_directory_is_safe() {
    local path="$1" mode
    [[ -d "$path" && ! -L "$path" && "$(readlink -m -- "$path")" == "$path" &&
       "$(stat -c %u -- "$path")" == "$EUID" ]] || return 1
    mode="$(stat -c %a -- "$path")"
    (( (8#$mode & 8#022) == 0 ))
}

browser_extension_policy_destination_is_safe() {
    local path="$1" parent
    [[ "$path" == /* && "$(readlink -m -- "$path")" == "$path" ]] || return 1
    parent="$(dirname -- "$path")"
    while [[ ! -e "$parent" && ! -L "$parent" ]]; do parent="$(dirname -- "$parent")"; done
    browser_extension_policy_directory_is_safe "$parent" || return 1
    if [[ -e "$path" || -L "$path" ]]; then
        browser_extension_policy_file_is_safe "$path" && [[ "$(stat -c %u -- "$path")" == "$EUID" ]]
    fi
}

browser_extension_policy_fingerprint() {
    if [[ -e "$1" || -L "$1" ]]; then sha256sum -- "$1"; else printf 'missing\n'; fi
}

browser_extension_policy_write() {
    local path="$1" expected="$2" contents="$3" temporary
    browser_extension_policy_destination_is_safe "$path" || return 1
    [[ "$(browser_extension_policy_fingerprint "$path")" == "$expected" ]] || {
        printf 'Browser extensions: policy changed during preparation: %s\n' "$path" >&2
        return 1
    }
    if [[ -f "$path" ]] && cmp -s "$path" <(printf '%s\n' "$contents"); then return 0; fi
    install -d -m 0755 -- "$(dirname -- "$path")"
    temporary="$(mktemp "$(dirname -- "$path")/.browser-extensions.XXXXXX")"
    printf '%s\n' "$contents" >"$temporary"
    chmod 0644 "$temporary"
    mv -Tf -- "$temporary" "$path"
}

configure_browser_extension_policies() (
    set -euo pipefail
    shopt -s nullglob
    umask 077
    [[ $# == 5 && "$1" =~ ^(apply|check)$ ]] || {
        printf 'Usage: browser-extensions.sh apply|check MANIFEST LIBREWOLF_DEFAULTS LIBREWOLF_POLICY HELIUM_MANAGED_DIR\n' >&2
        exit 2
    }
    local mode="$1" manifest="$2" defaults="$3" wolf_path="$4" helium_directory="$5"
    local config wolf_base wolf_existing='{"policies":{}}' wolf_desired helium_desired
    local helium_path="$helium_directory/install-system-browser-extensions.json" helium_base='{}' path count=0
    local wolf_before helium_before id url update_manifest update_data temporary="" wolf_output helium_output
    trap 'if [[ -n "$temporary" ]]; then rm -f -- "$temporary"; fi' EXIT

    browser_extension_policy_file_is_safe "$manifest" || exit 1
    browser_extension_policy_file_is_safe "$defaults" || exit 1
    browser_extension_policy_destination_is_safe "$wolf_path" || exit 1
    browser_extension_policy_destination_is_safe "$helium_path" || exit 1
    config="$(jq -e '
        def settings: type == "object" and length > 0;
        . as $config
        | type == "object" and (keys == ["helium", "librewolf"])
        and (.librewolf | keys == ["ExtensionSettings"])
        and (.helium | keys == ["ExtensionSettings"])
        and (.librewolf.ExtensionSettings | settings)
        and (.helium.ExtensionSettings | settings)
        and all(.librewolf.ExtensionSettings | to_entries[];
            .key != "*" and (.key | test("^[A-Za-z0-9@{}_.-]+$"))
            and .value.installation_mode == "normal_installed"
            and (.value | keys - ["installation_mode", "install_url", "private_browsing", "update_manifest_url"] | length == 0)
            and ((.value | has("private_browsing") | not) or (.value.private_browsing | type == "boolean"))
            and (if .value | has("update_manifest_url") then
                .key == "magnolia@12.34"
                and .value.update_manifest_url == "https://gitflic.ru/project/magnolia1234/bpc_updates/blob/raw?file=updates.json"
                and (.value | has("install_url") | not)
            else .value.install_url == ("https://addons.mozilla.org/firefox/downloads/latest/" + .key + "/latest.xpi") end))
        and all(.helium.ExtensionSettings | to_entries[];
            (.key | test("^[a-p]{32}$"))
            and (.value | keys == ["installation_mode", "update_url"])
            and .value.installation_mode == "normal_installed"
            and .value.update_url == "https://update-url-to-be-replaced.qjz9zk")
        | if . then $config else error("invalid extension manifest") end
    ' "$manifest")"
    wolf_base="$(jq -e 'select(type == "object" and (.policies | type == "object"))' "$defaults")"
    if [[ -e "$wolf_path" ]]; then
        wolf_existing="$(jq -e 'select(type == "object" and (.policies | type == "object"))' "$wolf_path")"
    fi
    wolf_before="$(browser_extension_policy_fingerprint "$wolf_path")"
    wolf_desired="$(jq -c '.librewolf.ExtensionSettings' <<<"$config")"
    helium_desired="$(jq -c '.helium.ExtensionSettings' <<<"$config")"

    # Chromium reads a shared policy namespace. Extend the existing settings file
    # instead of introducing a second competing ExtensionSettings dictionary.
    for path in "$helium_directory/"*.json; do
        browser_extension_policy_destination_is_safe "$path" || exit 1
        jq -e --argjson wanted "$helium_desired" '
            type == "object"
            and ((has("ExtensionInstallForcelist") | not) or (.ExtensionInstallForcelist | type == "array"))
            and ((has("ExtensionInstallBlocklist") | not) or (.ExtensionInstallBlocklist | type == "array"))
            and (any(.ExtensionInstallForcelist[]?; split(";")[0] as $id | $wanted | has($id)) | not)
            and (any(.ExtensionInstallBlocklist[]?; . == "*" or (. as $id | $wanted | has($id))) | not)
        ' "$path" >/dev/null || {
            printf 'Browser extensions: conflicting or invalid Helium legacy policy preserved: %s\n' "$path" >&2
            exit 1
        }
        if jq -e 'has("ExtensionSettings")' "$path" >/dev/null; then
            jq -e '.ExtensionSettings | type == "object"' "$path" >/dev/null
            helium_path="$path"
            count=$((count + 1))
        fi
    done
    ((count <= 1)) || {
        printf 'Browser extensions: competing Helium ExtensionSettings files preserved; resolve them first.\n' >&2
        exit 1
    }
    if [[ -e "$helium_path" ]]; then helium_base="$(jq -e 'select(type == "object")' "$helium_path")"; fi
    helium_before="$(browser_extension_policy_fingerprint "$helium_path")"

    while IFS=$'\t' read -r id update_manifest; do
        [[ -n "$id" ]] || continue
        url="$(jq -r --arg id "$id" '.policies.ExtensionSettings[$id].install_url // empty' <<<"$wolf_existing")"
        if [[ -z "$url" && "$mode" == apply ]]; then
            temporary="$(mktemp "${TMPDIR:-/tmp}/browser-extension-update.XXXXXX")"
            curl --fail --silent --show-error --location --retry 2 --connect-timeout 15 --max-time 120 \
                --proto '=https' --proto-redir '=https' --output "$temporary" "$update_manifest"
            update_data="$(jq -e --arg id "$id" '.addons[$id].updates | select(type == "array" and length > 0) | last
                | select((.version | type == "string") and (.update_link | type == "string"))' "$temporary")"
            url="$(jq -r '.update_link' <<<"$update_data")"
            rm -f -- "$temporary"
            temporary=""
        fi
        [[ "$url" =~ ^https://gitflic\.ru/project/magnolia1234/bpc_uploads/blob/raw\?file=bypass_paywalls_clean-[0-9]+(\.[0-9]+)*\.xpi$ ]] || {
            printf 'Browser extensions: missing or conflicting Bypass Paywalls Clean download URL; existing policies preserved.\n' >&2
            exit 1
        }
        wolf_desired="$(jq -c --arg id "$id" --arg url "$url" '
            .[$id] |= (del(.update_manifest_url) + {install_url: $url})' <<<"$wolf_desired")"
    done < <(jq -r '.librewolf.ExtensionSettings | to_entries[]
        | select(.value.update_manifest_url) | [.key, .value.update_manifest_url] | @tsv' <<<"$config")

    # Preserve unrelated keys and reject conflicting local fields, never reset them.
    local merge='def merge_settings($wanted):
        if type != "object" then error("invalid existing ExtensionSettings") else
        reduce ($wanted | to_entries[]) as $entry (.;
            if has($entry.key) and (.[$entry.key] | type != "object") then error("invalid existing extension entry") else . end
            | (.[$entry.key] // {}) as $current
            | reduce ($entry.value | to_entries[]) as $field (.;
                if ($current | has($field.key)) and $current[$field.key] != $field.value
                then error("conflicting existing extension field: " + $entry.key + "." + $field.key)
                else . end)
            | .[$entry.key] = ($current + $entry.value)) end;'
    wolf_output="$(jq --argjson base "$wolf_base" --argjson wanted "$wolf_desired" "$merge"'
        if any((.policies.Extensions.Uninstall[]?, .policies.Extensions.Locked[]?); . as $id | $wanted | has($id))
        then error("a requested extension has a conflicting legacy removal/lock policy") else . end
        | . as $existing | $base * $existing
        | .policies.ExtensionSettings = ((.policies.ExtensionSettings // {}) | merge_settings($wanted))
    ' <<<"$wolf_existing")"
    helium_output="$(jq --argjson wanted "$helium_desired" "$merge"'
        .ExtensionSettings = ((.ExtensionSettings // {}) | merge_settings($wanted))
    ' <<<"$helium_base")"

    if [[ "$mode" == check ]]; then
        # Validation is entirely local and does not fetch newer update manifests.
        jq -e --argjson expected "$wolf_output" '. == $expected' <<<"$wolf_existing" >/dev/null
        jq -e --argjson expected "$helium_output" '. == $expected' <<<"$helium_base" >/dev/null
        exit 0
    fi
    browser_extension_policy_write "$wolf_path" "$wolf_before" "$wolf_output"
    browser_extension_policy_write "$helium_path" "$helium_before" "$helium_output"
    printf 'Browser extension policies prepared; downloads occur when each browser starts online.\n'
)

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then configure_browser_extension_policies "$@"; fi
