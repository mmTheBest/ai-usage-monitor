#!/usr/bin/env bash
set -euo pipefail

CONFIG_DIR="${AI_USAGE_MONITOR_CONFIG_DIR:-$HOME/Library/Application Support/AIUsageMonitor}"
CONFIG_FILE="$CONFIG_DIR/accounts.json"
FORCE_SETUP="${AI_USAGE_MONITOR_FORCE_SETUP:-0}"

mkdir -p "$CONFIG_DIR"

has_enabled_accounts() {
  [[ -f "$CONFIG_FILE" ]] && /usr/bin/grep -q '"enabled"[[:space:]]*:[[:space:]]*true' "$CONFIG_FILE"
}

json_escape() {
  printf '%s' "$1" | /usr/bin/sed 's/\\/\\\\/g; s/"/\\"/g'
}

selected() {
  local needle="$1"
  local token
  for token in "${SELECTIONS[@]}"; do
    [[ "$token" == "$needle" ]] && return 0
  done
  return 1
}

read_secret() {
  local label="$1"
  local value
  read -r -p "$label (leave blank to configure later): " value
  printf '%s' "$value"
}

read_optional_usd() {
  local label="$1"
  local value
  while true; do
    read -r -p "$label (optional, USD): " value
    value="${value//[[:space:]]/}"
    if [[ -z "$value" || "$value" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
      printf '%s' "$value"
      return
    fi
    printf 'Enter a number like 25 or 25.50, or leave it blank.\n'
  done
}

append_account() {
  local block="$1"
  if [[ "$FIRST_ACCOUNT" == "0" ]]; then
    printf ',\n' >> "$TMP_FILE"
  fi
  printf '%s' "$block" >> "$TMP_FILE"
  FIRST_ACCOUNT=0
}

maybe_run_codex_login() {
  if ! command -v codex >/dev/null 2>&1; then
    printf 'Codex CLI was not found. Install Codex before using Codex subscription analytics.\n'
    return
  fi

  codex login status >/tmp/AIUsageMonitor-codex-login-status.log 2>&1 && return

  local answer
  read -r -p "Run Codex login now? [y/N]: " answer
  case "$answer" in
    y|Y|yes|YES)
      codex login || true
      ;;
  esac
}

if has_enabled_accounts && [[ "$FORCE_SETUP" != "1" ]]; then
  printf '\nAI Usage Monitor is already configured.\n'
  printf 'Config: %s\n\n' "$CONFIG_FILE"
  read -r -p "Press Return to launch, or type setup to change accounts: " action
  case "$action" in
    setup|Setup|SETUP|s|S|reconfigure|Reconfigure)
      ;;
    *)
      exit 0
      ;;
  esac
fi

cat <<'MENU'

AI Usage Monitor setup

Choose all subscriptions and API providers the desktop widget should show.
Enter numbers separated by commas or spaces.

  1  Codex subscription
  2  Claude Code local usage
  3  OpenAI API
  4  Anthropic API
  5  Gemini API
  6  DeepSeek API
  7  GLM API

Example: 1,2,3

MENU

read -r -p "Selection: " raw_selection
if [[ -z "${raw_selection//[[:space:],]/}" ]]; then
  printf 'No accounts selected. The widget will not open until setup is complete.\n'
  exit 1
fi

IFS=' ' read -r -a SELECTIONS <<< "${raw_selection//,/ }"
TMP_FILE="$(mktemp)"
FIRST_ACCOUNT=1

printf '{\n  "accounts": [\n' > "$TMP_FILE"

if selected "1"; then
  maybe_run_codex_login
  append_account '    {
      "id": "codex-subscription",
      "provider": "codex subscription",
      "label": "Codex",
      "enabled": true
    }'
fi

if selected "2"; then
  append_account '    {
      "id": "claude-code-local",
      "provider": "Claude subscription",
      "label": "Claude Code",
      "enabled": true
    }'
fi

if selected "3"; then
  printf '\nOpenAI API analytics uses organization usage and costs reports grouped by API key.\n'
  printf 'Use a developer-platform admin or usage-read credential, not a single app key.\n'
  openai_key="$(json_escape "$(read_secret "OpenAI platform/admin usage credential")")"
  [[ -z "$openai_key" ]] && openai_key="<OPENAI_ADMIN_ORG_KEY>"
  openai_budget="$(read_optional_usd "Monthly credit or budget used to show remaining balance")"
  openai_budget_line=""
  if [[ -n "$openai_budget" ]]; then
    openai_budget_line=$',
      "monthlyBudgetUSD": '"$openai_budget"
  fi
  append_account "    {
      \"id\": \"openai-main\",
      \"provider\": \"OpenAI API\",
      \"label\": \"OpenAI API\",
      \"platformCredential\": \"$openai_key\",
      \"usageEndpoint\": \"https://api.openai.com/v1/organization/usage/completions\",
      \"costEndpoint\": \"https://api.openai.com/v1/organization/costs\"$openai_budget_line,
      \"enabled\": true
    }"
fi

if selected "4"; then
  anthropic_key="$(json_escape "$(read_secret "Anthropic developer-platform usage credential")")"
  [[ -z "$anthropic_key" ]] && anthropic_key="<ANTHROPIC_ADMIN_USAGE_KEY>"
  append_account "    {
      \"id\": \"anthropic-main\",
      \"provider\": \"Anthropic API\",
      \"label\": \"Anthropic API\",
      \"platformCredential\": \"$anthropic_key\",
      \"usageEndpoint\": \"https://api.anthropic.com/v1/usage\",
      \"enabled\": true
    }"
fi

if selected "5"; then
  gemini_key="$(json_escape "$(read_secret "Gemini developer-platform usage credential")")"
  [[ -z "$gemini_key" ]] && gemini_key="<GEMINI_USAGE_CREDENTIAL>"
  append_account "    {
      \"id\": \"gemini-main\",
      \"provider\": \"Gemini API\",
      \"label\": \"Gemini API\",
      \"platformCredential\": \"$gemini_key\",
      \"usageEndpoint\": \"https://generativelanguage.googleapis.com/v1beta/usage\",
      \"balanceEndpoint\": \"https://generativelanguage.googleapis.com/v1beta/billing\",
      \"enabled\": true
    }"
fi

if selected "6"; then
  deepseek_key="$(json_escape "$(read_secret "DeepSeek account credential")")"
  [[ -z "$deepseek_key" ]] && deepseek_key="<DEEPSEEK_ACCOUNT_CREDENTIAL>"
  append_account "    {
      \"id\": \"deepseek-main\",
      \"provider\": \"DeepSeek API\",
      \"label\": \"DeepSeek API\",
      \"platformCredential\": \"$deepseek_key\",
      \"balanceEndpoint\": \"https://api.deepseek.com/user/balance\",
      \"enabled\": true
    }"
fi

if selected "7"; then
  glm_key="$(json_escape "$(read_secret "GLM developer-platform usage credential")")"
  [[ -z "$glm_key" ]] && glm_key="<GLM_USAGE_CREDENTIAL>"
  append_account "    {
      \"id\": \"glm-main\",
      \"provider\": \"GLM API\",
      \"label\": \"GLM API\",
      \"platformCredential\": \"$glm_key\",
      \"usageEndpoint\": \"https://open.bigmodel.cn/api/paas/v4/usage\",
      \"costEndpoint\": \"https://open.bigmodel.cn/api/paas/v4/usage\",
      \"enabled\": true
    }"
fi

printf '\n  ]\n}\n' >> "$TMP_FILE"

if [[ "$FIRST_ACCOUNT" == "1" ]]; then
  rm -f "$TMP_FILE"
  printf 'No valid accounts selected. The widget will not open until setup is complete.\n'
  exit 1
fi

mv "$TMP_FILE" "$CONFIG_FILE"
printf '\nSaved account selection to:\n%s\n\n' "$CONFIG_FILE"
