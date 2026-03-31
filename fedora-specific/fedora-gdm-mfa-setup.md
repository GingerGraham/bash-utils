# GDM MFA Setup on Fedora (TOTP + YubiKey)

Adds TOTP (Google Authenticator) and/or YubiKey U2F authentication to the GDM
password login path on Fedora. Fingerprint login is left unchanged — MFA only
applies when authenticating with a password.

This repository now includes an automation script (`gdm-mfa-setup.sh`) with:

* preflight gating
* deterministic PAM normalization
* rollback on failure
* dry-run support
* stage-based failure injection
* self-test mode

```
Boot / Screen unlock
├── Fingerprint → gdm-fingerprint PAM → no MFA
└── Password    → gdm-password PAM   → Password → MFA (TOTP or YubiKey)
```

The GNOME keyring continues to unlock normally because the password is verified
before MFA is evaluated, and `pam_gnome_keyring` captures it at that point.

---

## Scope and Compatibility

This setup is intended for systems that match all of the following:

* Fedora or RHEL-like distro behavior
* GNOME GDM with `/etc/pam.d/gdm-password`
* `dnf` package manager
* `authselect`
* SELinux tooling (`getenforce`, `checkmodule`, `semodule_package`, `semodule`)

If your environment differs (Debian/Ubuntu, non-GDM display managers, no
SELinux, no authselect), this procedure is not a drop-in fit.

The script prints a startup compatibility banner showing detected environment
details before proceeding.

---

## Script Usage

```bash
bash gdm-mfa-setup.sh \
  [--skip-totp] \
  [--skip-yubikey] \
  [--reset-totp] \
  [--reset-yubikey] \
  [--disable-totp] \
  [--disable-yubikey] \
  [--disable-mfa] \
  [--skip-authselect] \
  [--preflight] \
  [--dry-run] \
  [--inject-failure-at=<stage>] \
  [--self-test] \
  [--help|--help-full]
```

### Quick Start Paths

TOTP-only path (recommended for VM validation):

```bash
bash gdm-mfa-setup.sh --skip-yubikey
```

Full path (TOTP + YubiKey):

```bash
bash gdm-mfa-setup.sh
```

Safety-first dry-run before either path:

```bash
bash gdm-mfa-setup.sh --dry-run --skip-yubikey
```

Re-enroll TOTP after losing your authenticator app:

```bash
bash gdm-mfa-setup.sh --reset-totp
```

Remove all MFA and return to password-only login:

```bash
bash gdm-mfa-setup.sh --disable-mfa
```

### Mode notes

* `--preflight`: environment validation only; exits before setup
* `--dry-run`: no system mutations; prints what would change
* `--reset-totp`: re-enroll `~/.google_authenticator` and keep TOTP MFA enabled
* `--reset-yubikey`: replace current user mapping in `/etc/u2f_mappings` and keep YubiKey MFA enabled
* `--disable-totp`: disable TOTP MFA and remove `~/.google_authenticator` secret file
* `--disable-yubikey`: disable YubiKey MFA and remove current user from `/etc/u2f_mappings`
* `--disable-mfa`: disable both TOTP and YubiKey MFA (shorthand for `--disable-totp --disable-yubikey`)
* `--inject-failure-at=<stage>`: intentionally fails at a stage to exercise
  failure handling/rollback paths
* `--self-test`: runs all supported failure-injection stages in dry-run child
  executions and reports pass/fail summary

Reset option safety:

* `--reset-totp` cannot be combined with `--skip-totp`
* `--reset-yubikey` cannot be combined with `--skip-yubikey`

Disable option safety:

* `--disable-totp` cannot be combined with `--reset-totp`
* `--disable-yubikey` cannot be combined with `--reset-yubikey`
* `--disable-mfa` implies `--disable-totp` and `--disable-yubikey`
* Disable actions remove credential files and ensure clean removal from the PAM auth stack

Supported injection stages:

* `after-preflight`
* `after-snapshot`
* `after-packages`
* `after-authselect`
* `after-yubikey`
* `after-totp`
* `after-pam`
* `after-selinux`
* `before-pamtester`

---

## Prerequisites

```bash
sudo dnf install \
  google-authenticator \
  pam-u2f \
  pamu2fcfg \
  pamtester \
  policycoreutils-python-utils
```

---

## 1. Authselect Custom Profile

A custom profile is required so Fedora upgrades do not overwrite the
configuration.

The script uses the currently active authselect profile as the base and carries
its existing features forward, then ensures `with-fingerprint` is enabled.

> **Note:** `/etc/pam.d/gdm-password` is **not** managed by authselect — it is
> owned by GDM and safe to edit directly. The authselect profile step is still
> recommended to keep the rest of your PAM stack upgrade-safe.

Equivalent manual flow (illustrative):

```bash
current_profile="$(authselect current --raw | awk '{print $1}')"
sudo authselect create-profile mfa-login --base-on "$current_profile"
sudo authselect select custom/mfa-login with-fingerprint --force
```

Verify:

```bash
authselect current
# Profile ID: custom/mfa-login
# Enabled features:
# - with-fingerprint
```

Authselect stores a backup automatically at
`/var/lib/authselect/backups/<timestamp>/`. To restore:

```bash
sudo authselect backup-restore <timestamp>
```

---

## 2. Register YubiKey

Run the setup script as your regular user. During YubiKey registration, touch
the key when prompted.

```bash
sudo pamu2fcfg -u "$USER" > /etc/u2f_mappings
```

To add a backup key:

```bash
sudo pamu2fcfg -u "$USER" -n >> /etc/u2f_mappings
```

Script behavior notes:

* The script retries YubiKey capture up to 3 times before failing the step.
* Mapping material is written directly to `/etc/u2f_mappings` and is not dumped
  to console output.
* In VM environments (KVM/virt-manager), USB/FIDO passthrough must expose the
  YubiKey to the guest or `pamu2fcfg` will report no authenticator available.

The system-wide `/etc/u2f_mappings` file is used rather than the per-user
`~/.config/Yubico/u2f_keys` because GDM may not have access to home directories
at the point of authentication.

---

## 3. Set Up TOTP

Run as your regular user:

```bash
google-authenticator \
  --time-based \
  --disallow-reuse \
  --force \
  --rate-limit=3 \
  --rate-time=30 \
  --window-size=3
```

Scan the QR code with your TOTP app (Aegis, etc.). Save the emergency scratch
codes somewhere secure (e.g. Bitwarden).

The secret is stored at `~/.google_authenticator` with permissions `0400`.

---

## 4. Edit `/etc/pam.d/gdm-password`

Add two lines between `auth substack password-auth` and
`auth optional pam_gnome_keyring.so`.

The final `auth` section should look like this:

```
auth     [success=done ignore=ignore default=bad] pam_selinux_permit.so
auth        substack      password-auth
auth        [success=1 default=ignore]  pam_u2f.so authfile=/etc/u2f_mappings cue nouserok
auth        required      pam_google_authenticator.so nullok
auth        optional      pam_gnome_keyring.so
auth        include       postlogin
```

The `account`, `password`, and `session` sections are left unchanged.

**How the MFA logic works:**

* `[success=1 default=ignore]` on `pam_u2f` — if YubiKey succeeds, skip the
  next line (TOTP). If it fails or is absent, fall through to TOTP.
* `nouserok` — do not fail if the user has no YubiKey registered.
* `nullok` on `pam_google_authenticator` — do not fail if `~/.google_authenticator`
  does not exist. **Remove this once enrollment is confirmed working** to enforce
  TOTP for all users.

---

## 5. SELinux Policy

GDM runs under the `xdm_t` SELinux context. By default it is denied write
access to home directory files, which causes `pam_google_authenticator` to fail
when it tries to update `~/.google_authenticator` to record used codes
(required by `DISALLOW_REUSE`).

Create and install a custom policy module:

```bash
cat > gdm-google-auth.te << 'EOF'
module gdm-google-auth 1.0;

require {
    type xdm_t;
    type user_home_t;
    class file { create write rename unlink getattr setattr open read };
}

allow xdm_t user_home_t:file { create write rename unlink getattr setattr open read };
EOF

checkmodule -M -m -o gdm-google-auth.mod gdm-google-auth.te
semodule_package -o gdm-google-auth.pp -m gdm-google-auth.mod
sudo semodule -i gdm-google-auth.pp
```

Verify the module is loaded:

```bash
sudo semodule -l | grep -E 'gdm-google-auth|gdm_google_auth'
```

Some toolchains normalize dashes to underscores in module names; both forms are
valid for verification.

---

## 6. Testing

**Always test from a second open terminal before logging out.**

### pamtester

```bash
sudo pamtester -v gdm-password "$USER" authenticate
```

A successful TOTP run prompts for password then verification code.
A successful YubiKey run prompts for password then "Please touch the FIDO authenticator."

### Live journal monitoring

Run in a separate terminal while testing GDM lock/unlock:

```bash
sudo journalctl -f | grep -i "avc\|google\|gdm-password"
```

A clean TOTP success looks like:

```
gdm-password(pam_google_auth): Accepted google_authenticator for <user>
PAM:authentication grantors=pam_unix,pam_google_authenticator,pam_gnome_keyring res=success
```

No AVC denials should appear after the SELinux module is installed.

### Test order

1. Lock screen (`Super+L`) → unlock with password + TOTP
2. Lock screen → unlock with password + YubiKey
3. Full logout → login with each factor
4. Reboot → login with each factor

---

## 7. Final Hardening

Once both factors are confirmed working, remove `nullok` from the
`pam_google_authenticator` line to enforce TOTP for all users:

```
auth        required      pam_google_authenticator.so
```

---

## Troubleshooting

| Symptom                                              | Cause                                                   | Fix                                                                  |
| ---------------------------------------------------- | ------------------------------------------------------- | -------------------------------------------------------------------- |
| `Unrecognized option "nullokO"` in journal           | Typo in PAM config                                      | Check for `nullokO` vs `nullok`                                      |
| `Authentication failure` with no MFA prompt          | PAM module missing or error                             | Check `sudo pamtester -v` output and journal                         |
| `AVC denied { create }` in journal                   | SELinux policy not installed                            | Install `gdm-google-auth` policy module                              |
| `AVC denied { write / setattr }`                     | Incomplete SELinux policy                               | Rebuild policy with full file class permissions                      |
| SELinux module install succeeds but verify fails     | Module listed with underscore name (`gdm_google_auth`) | Verify with `sudo semodule -l | grep -E 'gdm-google-auth|gdm_google_auth'` |
| TOTP code rejected, time looks correct               | Code already used (`DISALLOW_REUSE`)                    | Wait for next 30s window                                             |
| `No FIDO authenticator available` during registration | YubiKey not visible inside VM/guest                     | Confirm USB/FIDO passthrough and test `pamu2fcfg -u "$USER"` in guest |
| YubiKey not prompted in GDM                          | Normal — GDM does not always show an explicit prompt    | Touch key when screen appears to be waiting                          |

---

## Recovery Shortcuts

If you need to return to a known-good baseline quickly:

```bash
# Restore previous authselect backup (pick a timestamp shown by authselect)
sudo authselect backup-list
sudo authselect backup-restore <timestamp>

# Revert custom SELinux module (if needed)
sudo semodule -r gdm-google-auth || sudo semodule -r gdm_google_auth
```

Then re-run a narrow validation path:

```bash
bash gdm-mfa-setup.sh --preflight
bash gdm-mfa-setup.sh --dry-run --skip-yubikey
```
