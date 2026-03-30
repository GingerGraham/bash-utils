#!/usr/bin/env bash
# gdm-mfa-setup.sh — Configure GDM password login to require TOTP and/or YubiKey MFA
#
# Adds multi-factor authentication (TOTP + YubiKey U2F/FIDO2) to GNOME GDM login.
# Tested on Fedora 43+ with authselect, PAM, dnf, and SELinux.
#
# Run as your regular user (not root). Sudo is used internally where needed.
# For detailed usage and options, run: bash gdm-mfa-setup.sh --help

set -Eeuo pipefail

# ── Colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; exit 1; }
step()    { echo -e "\n${BOLD}── $* ──${RESET}"; }

fail_with_context() {
  local step_name="$1"
  local expected_outcome="$2"
  local check_next="$3"
  local details="$4"
  echo -e "${RED}[ERROR]${RESET} Step failed: ${step_name}" >&2
  echo -e "${RED}[ERROR]${RESET} Expected outcome: ${expected_outcome}" >&2
  echo -e "${RED}[ERROR]${RESET} What to check: ${check_next}" >&2
  [[ -n "$details" ]] && echo -e "${RED}[ERROR]${RESET} Details: ${details}" >&2
  exit 1
}

ROLLBACK_DIR=''
ROLLBACK_ACTIVE=false
ROLLBACK_COMPLETED=false
AUTHSELECT_CHANGED=false
PAM_CHANGED=false
U2F_CHANGED=false
TOTP_CHANGED=false
SELINUX_CHANGED=false
DRY_RUN=false
PREFLIGHT_ONLY=false
INJECT_FAILURE_STAGE=''
SELF_TEST=false
SELF_TEST_CHILD=false
COMPATIBILITY_SUPPORTED=unknown
ORIG_AUTHSELECT_PROFILE=''
ORIG_AUTHSELECT_FEATURES=()
ORIG_U2F_EXISTS=false
ORIG_TOTP_EXISTS=false
SELINUX_MODULE_PREEXISTED=false

rollback_state() {
  if [[ "$ROLLBACK_ACTIVE" != true || "$ROLLBACK_COMPLETED" == true ]]; then
    return
  fi

  set +e
  warn "A failure occurred. Rolling back to your previous login state..."

  if [[ "$PAM_CHANGED" == true && -f "$ROLLBACK_DIR/gdm-password.orig" ]]; then
    if sudo cp "$ROLLBACK_DIR/gdm-password.orig" "$GDM_PAM"; then
      success "Rollback: restored $GDM_PAM"
    else
      warn "Rollback warning: failed to restore $GDM_PAM"
    fi
  fi

  if [[ "$AUTHSELECT_CHANGED" == true && -n "$ORIG_AUTHSELECT_PROFILE" ]]; then
    if sudo authselect select "$ORIG_AUTHSELECT_PROFILE" "${ORIG_AUTHSELECT_FEATURES[@]}" --force; then
      success "Rollback: restored authselect profile to '$ORIG_AUTHSELECT_PROFILE'"
    else
      warn "Rollback warning: failed to restore authselect profile '$ORIG_AUTHSELECT_PROFILE'"
    fi
  fi

  if [[ "$U2F_CHANGED" == true ]]; then
    if [[ "$ORIG_U2F_EXISTS" == true && -f "$ROLLBACK_DIR/u2f_mappings.orig" ]]; then
      if sudo cp "$ROLLBACK_DIR/u2f_mappings.orig" "$U2F_MAPPINGS"; then
        success "Rollback: restored $U2F_MAPPINGS"
      else
        warn "Rollback warning: failed to restore $U2F_MAPPINGS"
      fi
    elif [[ "$ORIG_U2F_EXISTS" == false ]]; then
      if sudo rm -f "$U2F_MAPPINGS"; then
        success "Rollback: removed newly created $U2F_MAPPINGS"
      else
        warn "Rollback warning: failed to remove newly created $U2F_MAPPINGS"
      fi
    fi
  fi

  if [[ "$TOTP_CHANGED" == true ]]; then
    if [[ "$ORIG_TOTP_EXISTS" == true && -f "$ROLLBACK_DIR/google_authenticator.orig" ]]; then
      if cp "$ROLLBACK_DIR/google_authenticator.orig" "$HOME/.google_authenticator"; then
        chmod 400 "$HOME/.google_authenticator" 2>/dev/null || true
        success "Rollback: restored $HOME/.google_authenticator"
      else
        warn "Rollback warning: failed to restore $HOME/.google_authenticator"
      fi
    elif [[ "$ORIG_TOTP_EXISTS" == false ]]; then
      if rm -f "$HOME/.google_authenticator"; then
        success "Rollback: removed newly created $HOME/.google_authenticator"
      else
        warn "Rollback warning: failed to remove newly created $HOME/.google_authenticator"
      fi
    fi
  fi

  if [[ "$SELINUX_CHANGED" == true && "$SELINUX_MODULE_PREEXISTED" == false ]]; then
    if sudo semodule -r "$SELINUX_MODULE_NAME"; then
      success "Rollback: removed SELinux module '$SELINUX_MODULE_NAME'"
    else
      warn "Rollback warning: failed to remove SELinux module '$SELINUX_MODULE_NAME'"
    fi
  fi

  ROLLBACK_COMPLETED=true
}

on_exit() {
  local exit_code=$?
  local gdm_pam_path="${GDM_PAM:-/etc/pam.d/gdm-password}"
  if [[ $exit_code -ne 0 ]]; then
    rollback_state
    warn "Script ended with failure. System was rolled back to pre-run state where possible."
    warn "If login behavior is still unexpected, verify $gdm_pam_path, authselect current profile, and journalctl output."
  fi

  if [[ -n "$ROLLBACK_DIR" && -d "$ROLLBACK_DIR" ]]; then
    rm -rf "$ROLLBACK_DIR" 2>/dev/null || true
  fi

  return $exit_code
}

trap on_exit EXIT
trap 'fail_with_context "Unhandled command failure" "Current operation completes successfully" "Review command output and fix the reported issue" "line=$LINENO command=$BASH_COMMAND"' ERR

is_dry_run() {
  [[ "$DRY_RUN" == true ]]
}

prompt_yes_no() {
  local prompt="$1"
  local default_answer="${2:-N}"
  local yn=''

  if is_dry_run; then
    info "[dry-run] Prompt skipped: ${prompt} (default ${default_answer})"
    return 1
  fi

  read -rp "$prompt" yn < /dev/tty
  [[ "${yn,,}" == "y" ]]
}

validate_injected_stage() {
  case "$INJECT_FAILURE_STAGE" in
    ''|after-preflight|after-snapshot|after-packages|after-authselect|after-yubikey|after-totp|after-pam|after-selinux|before-pamtester)
      ;;
    *)
      fail_with_context \
        "Injected failure option validation" \
        "--inject-failure-at uses a supported stage value" \
        "Choose one of: after-preflight, after-snapshot, after-packages, after-authselect, after-yubikey, after-totp, after-pam, after-selinux, before-pamtester" \
        "Unsupported stage: $INJECT_FAILURE_STAGE"
      ;;
  esac
}

maybe_inject_failure() {
  local stage="$1"
  if [[ -n "$INJECT_FAILURE_STAGE" && "$INJECT_FAILURE_STAGE" == "$stage" ]]; then
    fail_with_context \
      "Injected failure at stage '$stage'" \
      "Simulated failure occurs and rollback logic is exercised" \
      "Re-run without --inject-failure-at to execute normally" \
      "Intentional failure injection for resilience testing"
  fi
}

show_help_basic() {
  cat << 'EOF'
Usage: gdm-mfa-setup.sh [OPTIONS]

Configure GDM password login to require TOTP and/or YubiKey MFA.
Tested on Fedora 43+ with authselect, PAM, dnf, and SELinux.

Run as your regular user (not root)—sudo is used internally as needed.

═══════════════════════════════════════════════════════════════════════════════
OPTIONS
═══════════════════════════════════════════════════════════════════════════════

  --skip-totp                  Skip TOTP (Google Authenticator) setup
  --skip-yubikey               Skip YubiKey (U2F/FIDO2) setup
  --skip-authselect            Skip authselect custom profile setup
  --dry-run                    Preview all changes without system mutations
  --preflight                  Run environment validation only, exit without setup

  --help                       Show this help message
  --help-full                  Show extended help with testing/debugging options

═══════════════════════════════════════════════════════════════════════════════
EXAMPLES
═══════════════════════════════════════════════════════════════════════════════

# Standard setup: configure TOTP and YubiKey
bash gdm-mfa-setup.sh

# Preview all changes without modifying the system
bash gdm-mfa-setup.sh --dry-run

# Skip YubiKey, only set up TOTP (Google Authenticator)
bash gdm-mfa-setup.sh --skip-yubikey

# Skip both YubiKey and authselect profile configuration
bash gdm-mfa-setup.sh --skip-yubikey --skip-authselect

EOF
}

show_help_full() {
  cat << 'EOF'
Usage: gdm-mfa-setup.sh [OPTIONS]

Configure GDM password login to require TOTP and/or YubiKey MFA.
Tested on Fedora 43+ with authselect, PAM, dnf, and SELinux.

Run as your regular user (not root)—sudo is used internally as needed.

═══════════════════════════════════════════════════════════════════════════════
OPTIONS
═══════════════════════════════════════════════════════════════════════════════

Configuration Flags:
  --skip-totp                  Skip TOTP (Google Authenticator) setup
  --skip-yubikey               Skip YubiKey (U2F/FIDO2) setup
  --skip-authselect            Skip authselect custom profile setup

Testing & Debugging:
  --preflight                  Run environment validation only, exit without setup.
                               Useful for checking system compatibility.

  --dry-run                    Preview all changes without system mutations.
                               Useful for understanding impact before running.

  --self-test                  Run automated test suite. Executes script in child
                               processes at each major stage with intentional
                               failures to verify rollback mechanisms.

  --inject-failure-at=<STAGE>  Intentionally fail at a specific stage to test
                               rollback behavior. See INJECTION STAGES below.

Other:
  --help                       Show basic help message
  --help-full                  Show this extended help message

═══════════════════════════════════════════════════════════════════════════════
INJECTION STAGES
═══════════════════════════════════════════════════════════════════════════════

Use with --inject-failure-at=<STAGE> to test rollback at each phase:

  after-preflight              After environment validation (TTY, sudo, files)
  after-snapshot               After creating backup snapshots
  after-packages               After installing required packages
  after-authselect            After configuring authselect profile
  after-yubikey                After YubiKey U2F mapping setup
  after-totp                   After TOTP (Google Authenticator) setup
  after-pam                    After modifying GDM PAM stack (/etc/pam.d/gdm-password)
  after-selinux                After installing SELinux policy module
  before-pamtester             Before final PAM stack validation

═══════════════════════════════════════════════════════════════════════════════
EXAMPLES
═══════════════════════════════════════════════════════════════════════════════

# Standard setup: configure TOTP and YubiKey, customize authselect
bash gdm-mfa-setup.sh

# Preview all changes without modifying the system
bash gdm-mfa-setup.sh --dry-run

# Skip YubiKey, only set up TOTP (Google Authenticator)
bash gdm-mfa-setup.sh --skip-yubikey

# Test rollback behavior at PAM modification stage
bash gdm-mfa-setup.sh --inject-failure-at=after-pam

# Run full automated test suite (exercises all 9 injection stages)
bash gdm-mfa-setup.sh --self-test

EOF
}

run_self_test_suite() {
  step "Running self-test suite"

  local script_path=''
  local script_dir=''
  local script_name=''
  local -a stages
  local stage=''
  local output_file=''
  local pass_count=0
  local fail_count=0

  script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
  script_name="$(basename -- "${BASH_SOURCE[0]}")"
  script_path="$script_dir/$script_name"

  stages=(
    after-preflight
    after-snapshot
    after-packages
    after-authselect
    after-yubikey
    after-totp
    after-pam
    after-selinux
    before-pamtester
  )

  info "Self-test uses dry-run child executions (no system mutations)."

  for stage in "${stages[@]}"; do
    output_file="$(mktemp)"
    info "Self-test stage: $stage"

    if bash "$script_path" \
      --self-test-child \
      --dry-run \
      --skip-totp \
      --skip-yubikey \
      --skip-authselect \
      --inject-failure-at="$stage" \
      >"$output_file" 2>&1; then
      warn "Self-test failed: stage '$stage' unexpectedly exited successfully"
      warn "Expected an injected failure at stage '$stage'"
      fail_count=$((fail_count + 1))
    else
      if grep -q "Injected failure at stage '$stage'" "$output_file"; then
        success "Self-test passed: injected failure triggered at '$stage'"
        pass_count=$((pass_count + 1))
      else
        warn "Self-test failed: stage '$stage' did not fail for the expected reason"
        warn "Last 12 lines from child execution:"
        tail -n 12 "$output_file" || true
        fail_count=$((fail_count + 1))
      fi
    fi

    rm -f "$output_file" 2>/dev/null || true
  done

  echo ""
  info "Self-test summary: passed=$pass_count failed=$fail_count total=${#stages[@]}"

  if [[ "$fail_count" -gt 0 ]]; then
    fail_with_context \
      "Self-test suite" \
      "All failure-injection stages produce the expected controlled failure" \
      "Review failed stage logs above and re-run self-test" \
      "One or more self-test stages failed"
  fi

  success "Self-test suite completed successfully"
}

run_preflight_checks() {
  step "Running preflight checks"

  if is_dry_run; then
    info "Dry-run enabled: no system mutations will be applied"
  fi

  if ! is_dry_run && [[ "$SKIP_TOTP" == false || "$SKIP_YUBIKEY" == false ]]; then
    if [[ ! -t 0 ]]; then
      fail_with_context \
        "Interactive terminal preflight" \
        "Script has a TTY for MFA enrollment prompts" \
        "Run from an interactive terminal session" \
        "stdin is not a TTY but interactive enrollment is enabled"
    fi
  fi

  if is_dry_run; then
    if sudo -n true 2>/dev/null; then
      success "Preflight: sudo non-interactive check passed"
    else
      warn "Preflight: sudo credentials not cached (dry-run continues without elevation)"
      warn "For full execution later, run 'sudo -v' before starting the script"
    fi
  else
    if ! sudo -v; then
      fail_with_context \
        "Sudo preflight" \
        "Privileged commands can execute via sudo" \
        "Verify sudo access for this user and retry" \
        "sudo -v failed"
    fi
    success "Preflight: sudo access verified"
  fi

  if [[ ! -f "$GDM_PAM" ]]; then
    fail_with_context \
      "PAM file preflight" \
      "$GDM_PAM exists and is readable" \
      "Verify GDM installation and PAM file path" \
      "Missing file: $GDM_PAM"
  fi

  if [[ "$SKIP_TOTP" == false && ! -w "$HOME" ]]; then
    fail_with_context \
      "Home writeability preflight" \
      "Home directory is writable for TOTP secret creation" \
      "Check home directory ownership and permissions" \
      "Home directory not writable: $HOME"
  fi

  success "Preflight checks passed"
}

show_compatibility_banner() {
  step "Compatibility Banner"

  local os_id='unknown'
  local os_like=''
  local distro_ok=false

  if [[ -f /etc/os-release ]]; then
    os_id="$(awk -F= '$1=="ID"{gsub(/"/,"",$2); print $2; exit}' /etc/os-release)"
    os_like="$(awk -F= '$1=="ID_LIKE"{gsub(/"/,"",$2); print $2; exit}' /etc/os-release)"
    [[ -z "$os_id" ]] && os_id='unknown'
  fi

  case "$os_id" in
    fedora|rhel|centos|rocky|almalinux) distro_ok=true ;;
  esac

  if [[ "$distro_ok" == false && "$os_like" =~ (rhel|fedora) ]]; then
    distro_ok=true
  fi

  echo ""
  echo -e "${BOLD}Intended environment:${RESET} Fedora/RHEL-like Linux with GNOME GDM, PAM, authselect, dnf, and SELinux"
  echo -e "${BOLD}Detected environment:${RESET} ID=${os_id} ID_LIKE=${os_like:-<none>}"

  if [[ "$distro_ok" == true ]]; then
    COMPATIBILITY_SUPPORTED=true
    success "Distro family appears compatible"
  else
    COMPATIBILITY_SUPPORTED=false
    warn "Distro family may be incompatible with this script's assumptions"
  fi

  if command -v dnf >/dev/null 2>&1; then
    success "dnf detected"
  else
    warn "dnf not detected"
  fi

  if [[ -f /etc/pam.d/gdm-password ]]; then
    success "/etc/pam.d/gdm-password detected"
  else
    warn "/etc/pam.d/gdm-password not found"
  fi

  if command -v getenforce >/dev/null 2>&1; then
    info "SELinux mode: $(getenforce 2>/dev/null || echo unknown)"
  else
    warn "SELinux tools not detected (getenforce missing)"
  fi

  echo ""
}

require_cmd() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || \
    fail_with_context \
      "Prerequisite command check" \
      "Required command '$cmd' is available in PATH" \
      "Install the package providing '$cmd' and re-run" \
      "Command not found: $cmd"
}

# ── Options ───────────────────────────────────────────────────────────────────
SKIP_TOTP=false
SKIP_YUBIKEY=false
SKIP_AUTHSELECT=false

for arg in "$@"; do
  case "$arg" in
    --skip-totp)        SKIP_TOTP=true ;;
    --skip-yubikey)     SKIP_YUBIKEY=true ;;
    --skip-authselect)  SKIP_AUTHSELECT=true ;;
    --dry-run)          DRY_RUN=true ;;
    --preflight)        PREFLIGHT_ONLY=true ;;
    --inject-failure-at=*) INJECT_FAILURE_STAGE="${arg#*=}" ;;
    --self-test)        SELF_TEST=true ;;
    --self-test-child)  SELF_TEST_CHILD=true ;;
    --help)
      show_help_basic
      exit 0 ;;
    --help-full)
      show_help_full
      exit 0 ;;
    *) error "Unknown argument: $arg" ;;
  esac
done

validate_injected_stage

if [[ "$SELF_TEST" == true && "$SELF_TEST_CHILD" != true ]]; then
  run_self_test_suite
  exit 0
fi

# ── Sanity checks ─────────────────────────────────────────────────────────────
[[ "$EUID" -eq 0 ]] && error "Run as your regular user, not root."

if [[ "$PREFLIGHT_ONLY" == true ]]; then
  show_compatibility_banner
  run_preflight_checks
  success "Environment validation complete."
  exit 0
fi

CURRENT_USER="$USER"
GDM_PAM="/etc/pam.d/gdm-password"
U2F_MAPPINGS="/etc/u2f_mappings"
SELINUX_MODULE_NAME="gdm-google-auth"
AUTHSELECT_PROFILE="custom/mfa-login"

show_compatibility_banner

step "Checking prerequisites"

for cmd in sudo authselect rpm dnf grep sed awk mktemp; do
  require_cmd "$cmd"
done

# Check authselect current profile
CURRENT_PROFILE=$(authselect current --raw 2>/dev/null | head -1 || true)
if [[ -z "$CURRENT_PROFILE" ]]; then
  error "Could not determine current authselect profile. Is authselect installed?"
fi
info "Current authselect profile: $CURRENT_PROFILE"
ORIG_AUTHSELECT_PROFILE="$CURRENT_PROFILE"

# Capture enabled authselect features (e.g. with-fingerprint) for rollback.
mapfile -t ORIG_AUTHSELECT_FEATURES < <(authselect current 2>/dev/null | awk '/^- / {print $2}')

# Warn if not on 'local' profile
if [[ "$CURRENT_PROFILE" != "local" && "$CURRENT_PROFILE" != "$AUTHSELECT_PROFILE" ]]; then
  warn "Current profile is '$CURRENT_PROFILE', not 'local'."
  warn "The authselect step will use '$CURRENT_PROFILE' as the base. Review the result."
fi

run_preflight_checks
maybe_inject_failure "after-preflight"

step "Preparing rollback safety snapshot"

ROLLBACK_DIR=$(mktemp -d)
if [[ -z "$ROLLBACK_DIR" || ! -d "$ROLLBACK_DIR" ]]; then
  fail_with_context \
    "Rollback snapshot preparation" \
    "Temporary rollback directory is created" \
    "Check /tmp free space and filesystem permissions" \
    "mktemp failed while preparing rollback directory"
fi

if is_dry_run; then
  info "[dry-run] Rollback snapshots are not required because no mutations are applied"
else
  if ! sudo cp "$GDM_PAM" "$ROLLBACK_DIR/gdm-password.orig"; then
    fail_with_context \
      "Rollback snapshot preparation" \
      "Current $GDM_PAM is backed up before changes" \
      "Check sudo rights and read access to $GDM_PAM" \
      "Failed to snapshot $GDM_PAM"
  fi

  if [[ -f "$U2F_MAPPINGS" ]]; then
    ORIG_U2F_EXISTS=true
    if ! sudo cp "$U2F_MAPPINGS" "$ROLLBACK_DIR/u2f_mappings.orig"; then
      fail_with_context \
        "Rollback snapshot preparation" \
        "Current $U2F_MAPPINGS is backed up before changes" \
        "Check sudo rights and read access to $U2F_MAPPINGS" \
        "Failed to snapshot $U2F_MAPPINGS"
    fi
  fi

  if [[ -f "$HOME/.google_authenticator" ]]; then
    ORIG_TOTP_EXISTS=true
    if ! cp "$HOME/.google_authenticator" "$ROLLBACK_DIR/google_authenticator.orig"; then
      fail_with_context \
        "Rollback snapshot preparation" \
        "Current $HOME/.google_authenticator is backed up before changes" \
        "Check home directory permissions and file ownership" \
        "Failed to snapshot $HOME/.google_authenticator"
    fi
  fi

  if sudo semodule -l | grep -q "^${SELINUX_MODULE_NAME}[[:space:]]"; then
    SELINUX_MODULE_PREEXISTED=true
  fi

  ROLLBACK_ACTIVE=true
  success "Rollback safety snapshot prepared"
fi

maybe_inject_failure "after-snapshot"

# ── Step 1: Install packages ───────────────────────────────────────────────────
step "Installing required packages"

PACKAGES=(google-authenticator pam-u2f pamu2fcfg pamtester policycoreutils-python-utils)
MISSING=()

for pkg in "${PACKAGES[@]}"; do
  if ! rpm -q "$pkg" &>/dev/null; then
    MISSING+=("$pkg")
  else
    success "$pkg already installed"
  fi
done

if [[ ${#MISSING[@]} -gt 0 ]]; then
  info "Installing: ${MISSING[*]}"
  if is_dry_run; then
    info "[dry-run] Would run: sudo dnf install -y ${MISSING[*]}"
  else
    if ! sudo dnf install -y "${MISSING[@]}"; then
      fail_with_context \
        "Package installation" \
        "All required packages install successfully" \
        "Review dnf output, enabled repos, network connectivity, and package names" \
        "Failed packages: ${MISSING[*]}"
    fi

    for pkg in "${MISSING[@]}"; do
      if ! rpm -q "$pkg" &>/dev/null; then
        fail_with_context \
          "Package installation verification" \
          "Package '$pkg' is installed" \
          "Run 'sudo dnf install -y $pkg' and verify repo metadata" \
          "rpm -q $pkg reported package not installed"
      fi
    done
    success "Packages installed"
  fi
fi

maybe_inject_failure "after-packages"

if ! is_dry_run; then
  for cmd in google-authenticator pamu2fcfg pamtester checkmodule semodule_package semodule getenforce; do
    require_cmd "$cmd"
  done
else
  for cmd in google-authenticator pamu2fcfg pamtester checkmodule semodule_package semodule getenforce; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      warn "[dry-run] Missing command (would fail during real run): $cmd"
    fi
  done
fi

# ── Step 2: Authselect custom profile ─────────────────────────────────────────
if [[ "$SKIP_AUTHSELECT" == false ]]; then
  step "Creating authselect custom profile"

  if authselect list 2>/dev/null | grep -q "custom/mfa-login"; then
    warn "Profile 'custom/mfa-login' already exists — skipping creation"
  else
    BASE_PROFILE="$CURRENT_PROFILE"
    [[ "$BASE_PROFILE" == "$AUTHSELECT_PROFILE" ]] && BASE_PROFILE="local"
    if is_dry_run; then
      info "[dry-run] Would run: sudo authselect create-profile mfa-login --base-on $BASE_PROFILE"
    else
      if ! sudo authselect create-profile mfa-login --base-on "$BASE_PROFILE"; then
        fail_with_context \
          "Authselect profile creation" \
          "Custom profile '$AUTHSELECT_PROFILE' is created from base '$BASE_PROFILE'" \
          "Check base profile availability via 'authselect list' and sudo privileges" \
          "authselect create-profile failed"
      fi

      if ! authselect list 2>/dev/null | grep -q "custom/mfa-login"; then
        fail_with_context \
          "Authselect profile creation verification" \
          "Profile '$AUTHSELECT_PROFILE' exists" \
          "Inspect authselect output and /etc/authselect/custom" \
          "Profile not found after creation"
      fi
      success "Profile created from '$BASE_PROFILE'"
    fi
  fi

  if [[ "$CURRENT_PROFILE" != "$AUTHSELECT_PROFILE" ]]; then
    if is_dry_run; then
      info "[dry-run] Would run: sudo authselect select $AUTHSELECT_PROFILE with-fingerprint --force"
    else
      if ! sudo authselect select "$AUTHSELECT_PROFILE" with-fingerprint --force; then
        fail_with_context \
          "Authselect profile selection" \
          "Profile '$AUTHSELECT_PROFILE' with 'with-fingerprint' is active" \
          "Check authselect feature support and existing PAM customizations" \
          "authselect select failed"
      fi

      AUTHSELECT_CHANGED=true

      UPDATED_PROFILE=$(authselect current --raw 2>/dev/null | head -1 || true)
      if [[ "$UPDATED_PROFILE" != "$AUTHSELECT_PROFILE" ]]; then
        fail_with_context \
          "Authselect profile selection verification" \
          "Current authselect profile is '$AUTHSELECT_PROFILE'" \
          "Run 'authselect current' and verify no conflicting manual PAM edits" \
          "Current profile after selection: '${UPDATED_PROFILE:-unknown}'"
      fi
      success "Profile '$AUTHSELECT_PROFILE' with-fingerprint applied"
    fi
  else
    success "Profile '$AUTHSELECT_PROFILE' already active"
  fi

  info "Current profile:"
  authselect current
else
  warn "Skipping authselect step (--skip-authselect)"
fi

maybe_inject_failure "after-authselect"

# ── Step 3: Register YubiKey ───────────────────────────────────────────────────
if [[ "$SKIP_YUBIKEY" == false ]]; then
  step "Registering YubiKey"

  if is_dry_run; then
    info "[dry-run] Would verify/update $U2F_MAPPINGS for user '$CURRENT_USER'"
    if [[ -f "$U2F_MAPPINGS" ]]; then
      info "[dry-run] Existing mappings detected in $U2F_MAPPINGS"
    else
      info "[dry-run] $U2F_MAPPINGS does not exist and would be created"
    fi
  else
    # This step may alter mappings or permissions; enable rollback restoration.
    U2F_CHANGED=true

    if [[ -f "$U2F_MAPPINGS" ]] && ! sudo test -w "$U2F_MAPPINGS"; then
      fail_with_context \
        "YubiKey mapping file writeability check" \
        "Script can update $U2F_MAPPINGS via sudo" \
        "Check file permissions/ownership and sudo policy" \
        "No write access to $U2F_MAPPINGS"
    fi

    if [[ -f "$U2F_MAPPINGS" ]] && grep -q "^${CURRENT_USER}:" "$U2F_MAPPINGS" 2>/dev/null; then
      warn "YubiKey mapping for '$CURRENT_USER' already exists in $U2F_MAPPINGS"
      if prompt_yes_no "Register an additional/replacement key? [y/N] "; then
        info "Touch your YubiKey when prompted..."
        if ! MAPPING=$(pamu2fcfg -u "$CURRENT_USER"); then
          fail_with_context \
            "Primary YubiKey registration" \
            "A valid U2F mapping is generated for '$CURRENT_USER'" \
            "Ensure key is inserted/touched and supports U2F/FIDO2" \
            "pamu2fcfg failed while reading primary key"
        fi
        # Replace existing entry for this user
        ESCAPED_USER=$(printf '%s' "$CURRENT_USER" | sed 's/[][\\.^$*+?{}|()]/\\&/g')
        if ! sudo sed -i "/^${ESCAPED_USER}:/d" "$U2F_MAPPINGS"; then
          fail_with_context \
            "YubiKey mapping replacement" \
            "Existing mapping for '$CURRENT_USER' is replaced" \
            "Check sed availability, file permissions, and file format" \
            "Failed to remove old mapping entry"
        fi
        if ! echo "$MAPPING" | sudo tee -a "$U2F_MAPPINGS" > /dev/null; then
          fail_with_context \
            "YubiKey mapping replacement" \
            "New mapping for '$CURRENT_USER' is written to $U2F_MAPPINGS" \
            "Check sudo privileges and destination file permissions" \
            "Failed to append new mapping"
        fi
        U2F_CHANGED=true

        if ! grep -q "^${ESCAPED_USER}:" "$U2F_MAPPINGS" 2>/dev/null; then
          fail_with_context \
            "YubiKey mapping verification" \
            "Mapping file contains entry for '$CURRENT_USER'" \
            "Inspect $U2F_MAPPINGS contents and formatting" \
            "No user mapping found after update"
        fi
        success "YubiKey mapping updated"
      fi
    else
      info "Touch your YubiKey when prompted..."
      if ! MAPPING=$(pamu2fcfg -u "$CURRENT_USER"); then
        fail_with_context \
          "Primary YubiKey registration" \
          "A valid U2F mapping is generated for '$CURRENT_USER'" \
          "Ensure key is inserted/touched and supports U2F/FIDO2" \
          "pamu2fcfg failed while reading primary key"
      fi
      if ! echo "$MAPPING" | sudo tee -a "$U2F_MAPPINGS" > /dev/null; then
        fail_with_context \
          "Primary YubiKey registration" \
          "Mapping for '$CURRENT_USER' is appended to $U2F_MAPPINGS" \
          "Check sudo privileges and destination file permissions" \
          "Failed writing mapping file"
      fi
      U2F_CHANGED=true

      ESCAPED_USER=$(printf '%s' "$CURRENT_USER" | sed 's/[][\\.^$*+?{}|()]/\\&/g')
      if ! grep -q "^${ESCAPED_USER}:" "$U2F_MAPPINGS" 2>/dev/null; then
        fail_with_context \
          "Primary YubiKey registration verification" \
          "Mapping file contains entry for '$CURRENT_USER'" \
          "Inspect $U2F_MAPPINGS contents and formatting" \
          "No user mapping found after registration"
      fi
      success "YubiKey registered to $U2F_MAPPINGS"
    fi

    if prompt_yes_no "Register a backup YubiKey? [y/N] "; then
      info "Touch your backup YubiKey..."
      if ! pamu2fcfg -u "$CURRENT_USER" -n | sudo tee -a "$U2F_MAPPINGS" > /dev/null; then
        fail_with_context \
          "Backup YubiKey registration" \
          "Backup key mapping is appended for '$CURRENT_USER'" \
          "Ensure backup key is present/touched and supports U2F/FIDO2" \
          "pamu2fcfg failed while reading backup key"
      fi
      U2F_CHANGED=true
      success "Backup YubiKey registered"
    fi

    if ! sudo chmod 644 "$U2F_MAPPINGS"; then
      fail_with_context \
        "YubiKey mapping permissions" \
        "$U2F_MAPPINGS has mode 0644" \
        "Check file ownership and sudo permissions" \
        "chmod 644 failed on $U2F_MAPPINGS"
    fi

    U2F_MODE=$(stat -c '%a' "$U2F_MAPPINGS" 2>/dev/null || true)
    if [[ "$U2F_MODE" != "644" ]]; then
      fail_with_context \
        "YubiKey mapping permissions verification" \
        "$U2F_MAPPINGS mode is 644" \
        "Run 'sudo stat -c %a $U2F_MAPPINGS' and inspect ACLs" \
        "Current mode is '${U2F_MODE:-unknown}'"
    fi

    info "YubiKey mappings:"
    cat "$U2F_MAPPINGS"
  fi
else
  warn "Skipping YubiKey registration (--skip-yubikey)"
fi

maybe_inject_failure "after-yubikey"

# ── Step 4: TOTP setup ────────────────────────────────────────────────────────
if [[ "$SKIP_TOTP" == false ]]; then
  step "Setting up TOTP (Google Authenticator)"

  if is_dry_run; then
    if [[ -f "$HOME/.google_authenticator" ]]; then
      info "[dry-run] Existing $HOME/.google_authenticator found; would prompt before overwrite"
    else
      info "[dry-run] Would run google-authenticator to create $HOME/.google_authenticator"
    fi
  else

    if [[ -f "$HOME/.google_authenticator" ]]; then
      warn "$HOME/.google_authenticator already exists"
      if prompt_yes_no "Re-run google-authenticator and overwrite? [y/N] "; then
        SETUP_TOTP=true
      else
        info "Skipping TOTP setup"
      fi
    else
      SETUP_TOTP=true
    fi

    if [[ "${SETUP_TOTP:-false}" == true ]]; then
      echo ""
      info "Running google-authenticator. Scan the QR code with your TOTP app."
      info "Recommended answers: time-based=yes, update file=yes, disallow reuse=yes, rate limit=yes"
      echo ""
      if ! google-authenticator \
        --time-based \
        --disallow-reuse \
        --force \
        --rate-limit=3 \
        --rate-time=30 \
        --window-size=3; then
        fail_with_context \
          "TOTP setup" \
          "$HOME/.google_authenticator exists with a valid secret" \
          "Check terminal interactivity, QR enrollment prompts, and home directory permissions" \
          "google-authenticator command failed"
      fi
      TOTP_CHANGED=true

      if [[ ! -f "$HOME/.google_authenticator" ]]; then
        fail_with_context \
          "TOTP setup verification" \
          "$HOME/.google_authenticator is created" \
          "Check whether the tool was interrupted before writing the file" \
          "Secret file not found at $HOME/.google_authenticator"
      fi

      TOTP_MODE=$(stat -c '%a' "$HOME/.google_authenticator" 2>/dev/null || true)
      if [[ "$TOTP_MODE" != "400" ]]; then
        fail_with_context \
          "TOTP secret permissions verification" \
          "$HOME/.google_authenticator has mode 0400" \
          "Run 'chmod 400 ~/.google_authenticator' and verify ownership" \
          "Current mode is '${TOTP_MODE:-unknown}'"
      fi

      success "TOTP configured at ~/.google_authenticator"
    fi
  fi
else
  warn "Skipping TOTP setup (--skip-totp)"
fi

maybe_inject_failure "after-totp"

# ── Step 5: Edit /etc/pam.d/gdm-password ─────────────────────────────────────
step "Configuring /etc/pam.d/gdm-password"

if [[ ! -f "$GDM_PAM" ]]; then
  fail_with_context \
    "PAM file presence check" \
    "$GDM_PAM exists" \
    "Verify GDM is installed and the PAM file path is correct" \
    "PAM file does not exist: $GDM_PAM"
fi

# Check if MFA lines already present
if grep -q "pam_google_authenticator\|pam_u2f" "$GDM_PAM" 2>/dev/null; then
  warn "MFA lines appear to already be present in $GDM_PAM"
  grep -n "pam_google_authenticator\|pam_u2f" "$GDM_PAM"
  if is_dry_run; then
    info "[dry-run] Existing MFA lines detected; normalization preview will continue without prompting"
  elif ! prompt_yes_no "Continue and overwrite? [y/N] "; then
    warn "Skipping PAM edit"
    SKIP_PAM=true
  fi
fi

if [[ "${SKIP_PAM:-false}" != true ]]; then
  if ! grep -Eq "substack[[:space:]]+password-auth" "$GDM_PAM"; then
    fail_with_context \
      "PAM anchor validation" \
      "A line containing 'substack password-auth' exists in $GDM_PAM" \
      "Inspect $GDM_PAM auth section and adjust insertion anchor" \
      "Anchor line not found"
  fi

  # Back up original
  BACKUP_PATH="${GDM_PAM}.bak.$(date +%Y%m%d%H%M%S)"
  if is_dry_run; then
    info "[dry-run] Would create backup: $BACKUP_PATH"
  else
    if ! sudo cp "$GDM_PAM" "$BACKUP_PATH"; then
      fail_with_context \
        "PAM backup" \
        "Backup copy of $GDM_PAM is created" \
        "Check sudo rights and destination filesystem space" \
        "Failed to create backup at $BACKUP_PATH"
    fi

    if [[ ! -f "$BACKUP_PATH" ]]; then
      fail_with_context \
        "PAM backup verification" \
        "Backup file exists at $BACKUP_PATH" \
        "Verify backup path permissions and mount status" \
        "Backup file not found"
    fi

    success "Backup created: ${GDM_PAM}.bak.*"
  fi

  if [[ "$SKIP_YUBIKEY" == true && "$SKIP_TOTP" == true ]]; then
    warn "Both TOTP and YubiKey skipped — no MFA lines to insert"
  else
    ENABLE_U2F=false
    ENABLE_TOTP=false
    [[ "$SKIP_YUBIKEY" == false ]] && ENABLE_U2F=true
    [[ "$SKIP_TOTP" == false ]] && ENABLE_TOTP=true

    NORMALIZED_PAM="$ROLLBACK_DIR/gdm-password.normalized"
    if ! awk \
      -v enable_u2f="$ENABLE_U2F" \
      -v enable_totp="$ENABLE_TOTP" \
      '
        BEGIN { inserted=0 }
        {
          if ($0 ~ /^[[:space:]]*auth[[:space:]]+substack[[:space:]]+password-auth([[:space:]]|$)/) {
            print
            if (enable_u2f == "true") {
              print "auth        [success=1 default=ignore]  pam_u2f.so authfile=/etc/u2f_mappings cue nouserok"
            }
            if (enable_totp == "true") {
              print "auth        required      pam_google_authenticator.so nullok"
            }
            inserted=1
            next
          }

          if ($0 ~ /^[[:space:]]*auth[[:space:]].*pam_u2f\.so([[:space:]]|$)/) {
            next
          }

          if ($0 ~ /^[[:space:]]*auth[[:space:]].*pam_google_authenticator\.so([[:space:]]|$)/) {
            next
          }

          print
        }
        END {
          if (inserted == 0) {
            exit 3
          }
        }
      ' "$GDM_PAM" > "$NORMALIZED_PAM"; then
      fail_with_context \
        "PAM MFA stanza normalization" \
        "PAM file is rewritten with canonical MFA auth lines after the password-auth substack" \
        "Check anchor line, awk diagnostics, and write permissions" \
        "Failed to build normalized PAM file"
    fi

    if ! cmp -s "$GDM_PAM" "$NORMALIZED_PAM"; then
      if is_dry_run; then
        info "[dry-run] $GDM_PAM would be normalized to canonical MFA pattern"
      elif ! sudo cp "$NORMALIZED_PAM" "$GDM_PAM"; then
        fail_with_context \
          "PAM MFA stanza normalization apply" \
          "Normalized PAM content is written to $GDM_PAM" \
          "Check sudo access and target file permissions" \
          "Failed to replace PAM file with normalized content"
      else
        PAM_CHANGED=true
        success "$GDM_PAM normalized to canonical MFA pattern"
      fi
    else
      success "$GDM_PAM already matches canonical MFA pattern; no edit needed"
    fi

    PAM_VERIFY_FILE="$GDM_PAM"
    if is_dry_run; then
      PAM_VERIFY_FILE="$NORMALIZED_PAM"
    fi

    U2F_COUNT=$(grep -Ec "^[[:space:]]*auth[[:space:]].*pam_u2f\.so([[:space:]]|$)" "$PAM_VERIFY_FILE" || true)
    TOTP_COUNT=$(grep -Ec "^[[:space:]]*auth[[:space:]].*pam_google_authenticator\.so([[:space:]]|$)" "$PAM_VERIFY_FILE" || true)

    if [[ "$ENABLE_U2F" == true && "$U2F_COUNT" -ne 1 ]]; then
      fail_with_context \
        "PAM U2F normalization verification" \
        "Exactly one canonical U2F auth line exists" \
        "Inspect $GDM_PAM auth section for duplicate or malformed pam_u2f entries" \
        "Observed pam_u2f line count: $U2F_COUNT"
    fi

    if [[ "$ENABLE_U2F" == false && "$U2F_COUNT" -ne 0 ]]; then
      fail_with_context \
        "PAM U2F normalization verification" \
        "No U2F auth line exists when U2F is skipped" \
        "Inspect $GDM_PAM auth section for stale pam_u2f entries" \
        "Observed pam_u2f line count: $U2F_COUNT"
    fi

    if [[ "$ENABLE_TOTP" == true && "$TOTP_COUNT" -ne 1 ]]; then
      fail_with_context \
        "PAM TOTP normalization verification" \
        "Exactly one canonical TOTP auth line exists" \
        "Inspect $GDM_PAM auth section for duplicate or malformed pam_google_authenticator entries" \
        "Observed pam_google_authenticator line count: $TOTP_COUNT"
    fi

    if [[ "$ENABLE_TOTP" == false && "$TOTP_COUNT" -ne 0 ]]; then
      fail_with_context \
        "PAM TOTP normalization verification" \
        "No TOTP auth line exists when TOTP is skipped" \
        "Inspect $GDM_PAM auth section for stale pam_google_authenticator entries" \
        "Observed pam_google_authenticator line count: $TOTP_COUNT"
    fi
  fi

  info "Current auth section of $GDM_PAM:"
  grep "^auth" "$GDM_PAM"
fi

maybe_inject_failure "after-pam"

# ── Step 6: SELinux policy ────────────────────────────────────────────────────
step "Installing SELinux policy module"

SELINUX_MODE=$(getenforce 2>/dev/null || true)
if [[ -z "$SELINUX_MODE" ]]; then
  fail_with_context \
    "SELinux mode detection" \
    "SELinux mode is detectable via getenforce" \
    "Check SELinux tool installation and system policy state" \
    "getenforce returned no output"
fi

if [[ "$SELINUX_MODE" == "Disabled" ]]; then
  warn "SELinux is disabled; skipping module install because no policy enforcement is active"
  SELINUX_SKIPPED=true
fi

if [[ "${SELINUX_SKIPPED:-false}" != true ]]; then
  if sudo semodule -l | grep -q "^${SELINUX_MODULE_NAME}[[:space:]]"; then
    success "SELinux module '${SELINUX_MODULE_NAME}' already installed; no change needed"
  else
    if is_dry_run; then
      info "[dry-run] Would compile and install SELinux module '${SELINUX_MODULE_NAME}'"
    else
    WORKDIR=$(mktemp -d "$ROLLBACK_DIR/selinux.XXXXXX")
    if [[ -z "$WORKDIR" || ! -d "$WORKDIR" ]]; then
      fail_with_context \
        "SELinux temporary workspace creation" \
        "Temporary build directory is created" \
        "Check /tmp availability and filesystem permissions" \
        "mktemp -d failed"
    fi
    cat > "$WORKDIR/${SELINUX_MODULE_NAME}.te" << 'EOF'
module gdm-google-auth 1.0;

require {
    type xdm_t;
    type user_home_t;
    class file { create write rename unlink getattr setattr open read };
}

allow xdm_t user_home_t:file { create write rename unlink getattr setattr open read };
EOF

    if ! checkmodule -M -m \
      -o "$WORKDIR/${SELINUX_MODULE_NAME}.mod" \
      "$WORKDIR/${SELINUX_MODULE_NAME}.te"; then
      fail_with_context \
        "SELinux module compile" \
        "Policy source compiles into a .mod file" \
        "Review generated .te file and checkmodule diagnostics" \
        "checkmodule failed"
    fi

    if ! semodule_package \
      -o "$WORKDIR/${SELINUX_MODULE_NAME}.pp" \
      -m "$WORKDIR/${SELINUX_MODULE_NAME}.mod"; then
      fail_with_context \
        "SELinux module packaging" \
        "Compiled .mod file is packaged into a .pp module" \
        "Check semodule_package availability and input file permissions" \
        "semodule_package failed"
    fi

    if ! sudo semodule -i "$WORKDIR/${SELINUX_MODULE_NAME}.pp"; then
      fail_with_context \
        "SELinux module installation" \
        "Policy module '$SELINUX_MODULE_NAME' is installed" \
        "Inspect semodule output and verify SELinux is not disabled" \
        "semodule -i failed"
    fi
    SELINUX_CHANGED=true
    success "SELinux module '${SELINUX_MODULE_NAME}' installed"
    fi
  fi

  # Verify
  if is_dry_run; then
    info "[dry-run] Skipping strict SELinux activation verification"
  elif sudo semodule -l | grep -q "^${SELINUX_MODULE_NAME}[[:space:]]"; then
    success "SELinux module confirmed active:"
    sudo semodule -l | grep "^${SELINUX_MODULE_NAME}[[:space:]]"
  else
    fail_with_context \
      "SELinux module verification" \
      "Module '$SELINUX_MODULE_NAME' appears in semodule -l" \
      "Check semodule installation logs and module name consistency" \
      "Module not found after installation"
  fi
fi

maybe_inject_failure "after-selinux"

# ── Step 7: Test with pamtester ───────────────────────────────────────────────
step "Testing with pamtester"

maybe_inject_failure "before-pamtester"

echo ""
echo -e "${YELLOW}Running pamtester. Enter your password and MFA factor when prompted.${RESET}"
echo -e "${YELLOW}This tests the PAM stack without touching your live GDM session.${RESET}"
echo ""

if is_dry_run; then
  info "[dry-run] Would run: sudo pamtester -v gdm-password $CURRENT_USER authenticate"
else
  if sudo pamtester -v gdm-password "$CURRENT_USER" authenticate; then
    success "pamtester: authentication successful"
  else
    fail_with_context \
      "pamtester validation" \
      "PAM auth stack for gdm-password authenticates successfully with configured MFA" \
      "Run: sudo journalctl -xe | grep -i 'pam\\|google\\|gdm-password' | tail -30" \
      "pamtester authenticate failed"
  fi
fi

ROLLBACK_ACTIVE=false
ROLLBACK_COMPLETED=true

# ── Summary ───────────────────────────────────────────────────────────────────
step "Setup complete"

echo ""
echo -e "${BOLD}Next steps:${RESET}"
echo "  1. Test GDM lock screen unlock: Super+L, then password + MFA factor"
echo "  2. Test full logout → login"
echo "  3. Test reboot → login"
echo "  4. Once confirmed working, remove 'nullok' from $GDM_PAM:"
echo "       auth  required  pam_google_authenticator.so"
if [[ "$COMPATIBILITY_SUPPORTED" == false ]]; then
  echo ""
  echo -e "${YELLOW}${BOLD}Environment scope warning:${RESET}"
  echo "  This system does not look Fedora/RHEL-like based on /etc/os-release."
  echo "  This script targets GNOME GDM + PAM + authselect + dnf + SELinux workflows."
  echo "  Validate each step manually before relying on these changes."
fi
echo ""
echo -e "${BOLD}To monitor GDM auth attempts in real time:${RESET}"
echo "  sudo journalctl -f | grep -i 'avc\\|google\\|gdm-password'"
echo ""
echo -e "${BOLD}Authselect backup location:${RESET}"
{ find /var/lib/authselect/backups/ -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null || true; } | sort | tail -3 | \
  sed 's#^#  /var/lib/authselect/backups/#'
echo ""
