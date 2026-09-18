#!/usr/bin/env bash
#
# setup.sh — prepare a control machine to run this repo
#
# Blank machine + git clone + carry-out secrets  ->  ready to deploy.
# Idempotent. Safe to re-run at any time.
#
# Every check below exists because it failed during a real clean-machine
# rebuild. Nothing here is theoretical.
#
# Carry-out secrets (password manager, never in git):
#   1. SSH private key  -> ~/.ssh/id_ed25519_<env>
#   2. Vault password   -> ~/.ansible/vault_pass_<env>
#   3. Restic password  -> configured in Backrest, not needed here

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MIN_ANSIBLE_CORE="2.17"

# Galaxy content installs OUTSIDE the repo to keep the tree clean.
GALAXY_ROLES_PATH="${HOME}/.ansible/roles"

# Vault helper functions live outside the repo and are sourced from your
# shell rc. Keeping them out of the tree means they are never committed.
VAULT_ALIASES="${HOME}/.ansible/vault_aliases.sh"

# Environments this control machine drives.
# Add "work" once inventory/group_vars/work/ exists.
ENVIRONMENTS=("homelab")

# Non-interactive mode for CI or unattended re-runs. Never prompts; fails
# instead. Enable with: NONINTERACTIVE=1 ./setup.sh
NONINTERACTIVE="${NONINTERACTIVE:-0}"

RED=$'\033[0;31m'; GRN=$'\033[0;32m'; YLW=$'\033[0;33m'; NC=$'\033[0m'
WARN_COUNT=0

ok()   { echo "${GRN}  ok${NC}    $*"; }
warn() { echo "${YLW}  warn${NC}  $*"; WARN_COUNT=$((WARN_COUNT + 1)); }
die()  { echo "${RED}  FAIL${NC}  $*" >&2; exit 1; }
step() { echo; echo "==> $*"; }

echo "=========================================="
echo " ansible-infra — control machine bootstrap"
echo "=========================================="

# Refuse to run as root. Running as root creates root-owned files in ~/.ssh
# and ~/.ansible, then normal-user runs fail with confusing permission errors.
if [ "$(id -u)" -eq 0 ]; then
    die "do not run as root — run as your normal user (sudo is called where needed)"
fi

# Paths in ansible.cfg are repo-relative, so we must run from the root.
[ -f "${REPO_DIR}/ansible.cfg" ]      || die "ansible.cfg not found — run from the repo root"
[ -f "${REPO_DIR}/requirements.yml" ] || die "requirements.yml not found — run from the repo root"
cd "$REPO_DIR"

# ---------------------------------------------------------------------------
step "1/11  System packages"
# ---------------------------------------------------------------------------
# sshpass    : the proxmox role uses password SSH to the hypervisor
# cifs-utils : the kernel performs the CIFS mount, needed even with
#              docker cifs volumes
command -v apt-get >/dev/null 2>&1 || die "this script assumes apt (Debian/Ubuntu/WSL)"

PKGS=(curl git pipx sshpass cifs-utils)
MISSING=()
for p in "${PKGS[@]}"; do
    dpkg -s "$p" >/dev/null 2>&1 || MISSING+=("$p")
done

if [ ${#MISSING[@]} -gt 0 ]; then
    echo "    installing: ${MISSING[*]}"
    sudo apt-get update -qq
    sudo apt-get install -y "${MISSING[@]}"
fi
ok "packages present"

# ---------------------------------------------------------------------------
step "1b/11  Local
e support"
# ---------------------------------------------------------------------------
# VS Code, Git extensions, pre-commit and some Python tools occasionally
# launch with LC_ALL=en_US.UTF-8 even when the interactive shell uses
# C.UTF-8. If the locale does not exist, commits from GUI clients can fail
# with:
#
#   setlocale: LC_ALL: cannot change locale (en_US.UTF-8)
#   Ansible could not initialize the preferred locale
#
# Generating the locale is harmless and prevents those failures.

if ! locale -a 2>/dev/null | grep -qi '^en_US\.utf8$'; then
    echo "    enabling en_US.UTF-8 locale"

    dpkg -s locales >/dev/null 2>&1 || {
        sudo apt-get update -qq
        sudo apt-get install -y locales
    }

    sudo locale-gen en_US.UTF-8 >/dev/null
fi

ok "locale support present"

# ---------------------------------------------------------------------------
step "2/11  Ansible"
# ---------------------------------------------------------------------------
# The distro ansible package is typically too old for community.proxmox 2.x
# and will shadow the pipx install if both are present.
if dpkg -s ansible-core >/dev/null 2>&1 || dpkg -s ansible >/dev/null 2>&1; then
    warn "distro ansible package is installed and may shadow the pipx version"
    warn "  sudo apt remove ansible ansible-core"
fi

# pipx install exits non-zero when already installed, which set -e would
# turn into an abort. Check first so re-runs are safe.
if pipx list 2>/dev/null | grep -q ansible-core; then
    ok "ansible-core already installed via pipx"
else
    pipx install ansible-core
fi

# pre-commit and ansible-lint go through pipx for the same reason as
# ansible-core: the distro versions lag, and the git hooks run offline
# against whatever is on PATH.
for TOOL in pre-commit ansible-lint; do
    if pipx list 2>/dev/null | grep -q "package ${TOOL} "; then
        ok "${TOOL} already installed via pipx"
    else
        echo "    installing ${TOOL}"
        pipx install "$TOOL"
    fi
done

pipx ensurepath >/dev/null 2>&1 || true
export PATH="${HOME}/.local/bin:${PATH}"   # prepend so pipx wins over apt

command -v ansible >/dev/null 2>&1 || die "ansible not on PATH — restart your shell and re-run"

CORE_VER="$(ansible --version | sed -n 's/.*core \([0-9.]*\).*/\1/p' | head -1)"
if [ -n "$CORE_VER" ] && \
   [ "$(printf '%s\n%s' "$MIN_ANSIBLE_CORE" "$CORE_VER" | sort -V | head -1)" != "$MIN_ANSIBLE_CORE" ]; then
    warn "ansible-core ${CORE_VER} is older than ${MIN_ANSIBLE_CORE}"
    warn "community.proxmox 2.x will warn and may misbehave"
else
    ok "ansible-core ${CORE_VER}"
fi

# ---------------------------------------------------------------------------
step "3/11  Repo integrity"
# ---------------------------------------------------------------------------
# main once shipped committed merge conflict markers, so a fresh clone did
# not parse. Ansible reported it as a quoting problem, which sent debugging
# in the wrong direction. Catch it explicitly.
if grep -rn '^<<<<<<< \|^>>>>>>> ' . --exclude-dir=.git -q 2>/dev/null; then
    echo
    grep -rn '^<<<<<<< \|^>>>>>>> ' . --exclude-dir=.git 2>/dev/null || true
    echo
    die "merge conflict markers in tracked files (listed above) — resolve first"
fi
ok "no conflict markers"

# A second 'roles:' block silently overwrites the first, so those roles
# never install and the failure only shows up much later.
if [ "$(grep -c '^roles:' requirements.yml)" -gt 1 ]; then
    die "requirements.yml declares 'roles:' more than once — the later block wins"
fi
if [ "$(grep -c '^collections:' requirements.yml)" -gt 1 ]; then
    die "requirements.yml declares 'collections:' more than once — the later block wins"
fi
ok "requirements.yml well-formed"

# Duplicate YAML keys resolve to the last value with no error at all.
# Editing the first definition then appears to do nothing.
shopt -s nullglob
for VF in inventory/group_vars/*/vars.yml inventory/host_vars/*/main.yml; do
    [ -f "$VF" ] || continue
    DUPES="$(grep -oE '^[a-zA-Z_][a-zA-Z0-9_]*:' "$VF" | sort | uniq -d || true)"
    if [ -n "$DUPES" ]; then
        warn "duplicate keys in ${VF} (last definition wins):"
        echo "$DUPES" | sed 's/^/          /'
    fi
done
shopt -u nullglob

if git rev-parse --git-dir >/dev/null 2>&1; then
    # Cleartext credentials have been committed to this repo before.
    STRAYS="$(git ls-files | grep -iE '(vault.*\.(tmp|bak|orig)|\.bak.*$|copy\.tmp)' || true)"
    if [ -n "$STRAYS" ]; then
        warn "backup/temp files are tracked by git:"
        echo "$STRAYS" | sed 's/^/          /'
        warn "remove with: git rm --cached <file>"
    fi

    # Galaxy content belongs in ${GALAXY_ROLES_PATH}, not in the repo tree.
    VENDORED="$(git ls-files | grep -E '^roles/(geerlingguy\.|os-hardening)' | cut -d/ -f2 | sort -u || true)"
    if [ -n "$VENDORED" ]; then
        warn "galaxy roles are tracked in the repo:"
        echo "$VENDORED" | sed 's/^/          /'
        warn "untrack with: git rm -r --cached roles/<name>"
    fi

    # An unencrypted vault must never reach a commit. The pre-commit hook
    # only sees staged changes, so it cannot catch a vault committed
    # unencrypted before the hooks existed. This check can.
    while IFS= read -r VFILE; do
        [ -n "$VFILE" ] || continue
        head -1 "$VFILE" | grep -q '^\$ANSIBLE_VAULT' \
            || die "TRACKED BUT UNENCRYPTED: ${VFILE} — run: ansible-vault encrypt ${VFILE}"
    done < <(git ls-files | grep -E 'vault.*\.ya?ml$' || true)
fi
ok "repo structure checks complete"

# ---------------------------------------------------------------------------
step "4/11  Git hooks"
# ---------------------------------------------------------------------------
# Hooks are the last line of defence before a secret reaches the remote.
# .pre-commit-config.yaml uses only `repo: local` hooks, so nothing is
# cloned at install time and the hooks work on an air-gapped machine.
if ! git rev-parse --git-dir >/dev/null 2>&1; then
    warn "not a git repository — skipping hook install"
elif [ ! -f .pre-commit-config.yaml ]; then
    warn ".pre-commit-config.yaml not found — commits are unprotected"
    warn "  secrets, unencrypted vaults and backup files will not be blocked"
else
    command -v pre-commit >/dev/null 2>&1 || die "pre-commit not on PATH — restart your shell and re-run"

    # Installing over an existing hook is safe; pre-commit moves any
    # foreign hook aside rather than clobbering it.
    pre-commit install >/dev/null
    pre-commit install --hook-type pre-push >/dev/null
    ok "pre-commit and pre-push hooks installed"

    # The syntax-check hook shells out to ansible-playbook, the lint hook
    # to ansible-lint. Both must resolve without your interactive shell,
    # which is how git invokes hooks from GUI clients.
    command -v ansible-lint >/dev/null 2>&1 \
        || warn "ansible-lint not on PATH — the pre-push hook will fail"

    case ":${PATH}:" in
        *":${HOME}/.local/bin:"*) : ;;
        *)
            warn "~/.local/bin is not on PATH — hooks run from a GUI git client will fail"
            warn "  pipx ensurepath, then restart your shell"
            ;;
    esac

    # Prove the hooks actually fire before trusting them. Non-fatal: a
    # fresh clone may still contain the .bak files being cleaned up.
    if pre-commit run --all-files >/dev/null 2>&1; then
        ok "hooks pass against the current tree"
    else
        warn "hooks report findings against the current tree"
        warn "  see details with: pre-commit run --all-files"
    fi
fi

# ---------------------------------------------------------------------------
step "5/11  Galaxy collections and roles"
# ---------------------------------------------------------------------------
# Paths come from ansible.cfg (roles_path, collections_path), both outside
# the repo. Roles and collections install separately.
ansible-galaxy role install -r requirements.yml >/dev/null
ansible-galaxy collection install -r requirements.yml >/dev/null
ok "roles and collections installed"

# ---------------------------------------------------------------------------
step "6/11  SSH keys"
# ---------------------------------------------------------------------------
# The control machine is disposable ONLY if identity is injectable.
# Losing this key previously cost administrative access to the estate.
if [ -z "${SSH_AUTH_SOCK:-}" ] && command -v ssh-agent >/dev/null 2>&1; then
    eval "$(ssh-agent -s)" >/dev/null
fi

mkdir -p "${HOME}/.ssh" && chmod 700 "${HOME}/.ssh"

for ENV in "${ENVIRONMENTS[@]}"; do
    KEY="${HOME}/.ssh/id_ed25519_${ENV}"
    PUB="files/ssh/${ENV}.pub"

    if [ ! -f "$KEY" ]; then
        echo
        echo "  ${RED}Missing SSH private key:${NC} ${KEY}"
        echo
        echo "  Carry-out secret. Normally you paste this from your password manager."
        echo

        if [ "$NONINTERACTIVE" = "1" ]; then
            die "no SSH key for ${ENV} and NONINTERACTIVE=1"
        fi

        read -rp "  [g]enerate a new key, or [a]bort and paste it manually? " CHOICE
        case "$CHOICE" in
            g|G)
                ssh-keygen -t ed25519 -C "aviel-${ENV}" -f "$KEY"
                mkdir -p files/ssh
                ssh-keygen -y -f "$KEY" > "$PUB"
                echo
                echo "  ${YLW}New key generated.${NC}"
                echo "  1. Store the PRIVATE key in your password manager now:  ${KEY}"
                echo "  2. Commit the public half:  ${PUB}"
                echo "  3. Existing hosts will NOT trust this key until you add it:"
                echo "       ssh-copy-id -i ${KEY}.pub <user>@<host>"
                echo "     or via the Proxmox console if SSH is already locked out."
                echo
                read -rp "  Press enter once the private key is saved. " _
                ;;
            *)
                cat >&2 <<EOF

      mkdir -p ~/.ssh
      # paste the private key into ${KEY}
      chmod 600 ${KEY}

EOF
                die "cannot proceed without the ${ENV} SSH key"
                ;;
        esac
    fi

    [ "$(stat -c '%a' "$KEY")" = "600" ] || { chmod 600 "$KEY"; warn "fixed permissions on ${KEY}"; }

    # Compare by fingerprint — matching on the file path is unreliable.
    KEY_FP="$(ssh-keygen -lf "$KEY" 2>/dev/null | awk '{print $2}')"
    if ! ssh-add -l 2>/dev/null | grep -q "$KEY_FP"; then
        ssh-add "$KEY" 2>/dev/null \
            || warn "could not add ${ENV} key to agent — passphrase may be prompted per host"
    fi

    # The public half must be committed so cloud-init trusts it on new VMs.
    # Filename must be <env>.pub — cloud-init templates look it up by env name.
    if [ ! -f "$PUB" ]; then
        warn "${PUB} missing — new VMs will not trust this key at birth"
        warn "  ssh-keygen -y -f ${KEY} > ${PUB}"
    elif ! diff -q <(ssh-keygen -y -f "$KEY") "$PUB" >/dev/null 2>&1; then
        warn "${PUB} does not match ${KEY} — new VMs will trust the WRONG key"
        warn "  ssh-keygen -y -f ${KEY} > ${PUB}"
    fi

    ok "${ENV} ssh key ready"
done

# ---------------------------------------------------------------------------
step "7/11  Vault password"
# ---------------------------------------------------------------------------
mkdir -p "${HOME}/.ansible" && chmod 700 "${HOME}/.ansible"

for ENV in "${ENVIRONMENTS[@]}"; do
    VAULT_PASS="${HOME}/.ansible/vault_pass_${ENV}"
    VAULT_FILE="inventory/group_vars/${ENV}/vault.yml"

    if [ ! -f "$VAULT_PASS" ]; then
        echo
        echo "  Vault password file not found: ${VAULT_PASS}"
        echo "  There is no recovery path for this secret. The Proxmox console"
        echo "  cannot help. If lost, every encrypted value must be regenerated."
        echo

        if [ "$NONINTERACTIVE" = "1" ]; then
            die "no vault password for ${ENV} and NONINTERACTIVE=1"
        fi

        # Only offer to generate when no encrypted vault exists yet —
        # generating a new password against an existing vault guarantees
        # it will not decrypt.
        if [ -f "$VAULT_FILE" ] && head -1 "$VAULT_FILE" 2>/dev/null | grep -q '^\$ANSIBLE_VAULT'; then
            echo "  An encrypted vault already exists, so the password must be"
            echo "  the original one. Retrieve it from your password manager."
            echo
            read -rsp "  Enter ${ENV} vault password: " VP
            echo
            [ -n "$VP" ] || die "empty vault password"
            printf '%s' "$VP" > "$VAULT_PASS"
            unset VP
        else
            read -rp "  [r]etrieve from password manager, or [g]enerate a new one? " CHOICE
            case "$CHOICE" in
                g|G)
                    openssl rand -base64 48 | tr -d '\n' > "$VAULT_PASS"
                    echo
                    echo "  ${YLW}Generated. Store this in your password manager NOW:${NC}"
                    echo
                    echo "      $(cat "$VAULT_PASS")"
                    echo
                    read -rp "  Press enter once saved. " _
                    ;;
                *)
                    read -rsp "  Enter ${ENV} vault password: " VP
                    echo
                    [ -n "$VP" ] || die "empty vault password"
                    printf '%s' "$VP" > "$VAULT_PASS"
                    unset VP
                    ;;
            esac
        fi
    fi

    chmod 600 "$VAULT_PASS"

    # A trailing newline written by an editor changes the password and
    # produces a confusing "decryption failed" later.
    if [ -z "$(tail -c1 "$VAULT_PASS")" ]; then
        warn "${VAULT_PASS} ends with a newline — stripping it"
        printf '%s' "$(cat "$VAULT_PASS")" > "${VAULT_PASS}.new"
        mv "${VAULT_PASS}.new" "$VAULT_PASS"
        chmod 600 "$VAULT_PASS"
    fi

    ok "${ENV} vault password file present"
done

# ansible.cfg must actually point at the password file, or none of this is
# used — including by the pre-commit syntax-check hook.
if ! grep -qE '^\s*(vault_password_file|vault_identity_list)' ansible.cfg; then
    warn "ansible.cfg has no vault_password_file or vault_identity_list"
    warn "  add:  vault_password_file = ~/.ansible/vault_pass_${ENVIRONMENTS[0]}"
fi

# ---------------------------------------------------------------------------
step "8/11  Vault decrypts"
# ---------------------------------------------------------------------------
# A password manager entry never tested against the file is not a backup.
for ENV in "${ENVIRONMENTS[@]}"; do
    VAULT_FILE="inventory/group_vars/${ENV}/vault.yml"

    if [ ! -f "$VAULT_FILE" ]; then
        warn "no vault at ${VAULT_FILE}"
        warn "keys referenced in code:"
        grep -rhoE 'vault_[a-zA-Z0-9_]+' roles/ inventory/ 2>/dev/null \
            | sort -u | sed 's/^/          /'
        die "create and encrypt ${VAULT_FILE} before deploying"
    fi

    head -1 "$VAULT_FILE" | grep -q '^\$ANSIBLE_VAULT' \
        || die "${VAULT_FILE} is NOT encrypted — run: ansible-vault encrypt ${VAULT_FILE}"

    ansible-vault view "$VAULT_FILE" >/dev/null 2>&1 \
        || die "the ${ENV} vault password does not decrypt ${VAULT_FILE}"
    ok "${VAULT_FILE} decrypts"

    # Catch keys referenced in code but absent from the vault, before a
    # playbook run fails on 'undefined variable' mid-deploy.
    REFERENCED="$(grep -rhoE 'vault_[a-zA-Z0-9_]+' roles/ inventory/ 2>/dev/null | sort -u || true)"
    DEFINED="$(ansible-vault view "$VAULT_FILE" 2>/dev/null | grep -oE '^vault_[a-zA-Z0-9_]+' | sort -u || true)"
    UNDEFINED="$(comm -23 <(echo "$REFERENCED") <(echo "$DEFINED") 2>/dev/null || true)"
    if [ -n "$UNDEFINED" ]; then
        warn "referenced in code but not defined in ${VAULT_FILE}:"
        echo "$UNDEFINED" | sed 's/^/          /'
        warn "either add these keys, or rename the references to match the vault"
    fi

    # Empty values are a common half-finished-vault failure.
    EMPTY="$(ansible-vault view "$VAULT_FILE" 2>/dev/null | grep -E '^vault_[a-zA-Z0-9_]+:[[:space:]]*("")?[[:space:]]*$' || true)"
    if [ -n "$EMPTY" ]; then
        warn "empty values in ${VAULT_FILE}:"
        echo "$EMPTY" | sed 's/^/          /'
    fi
done

# ---------------------------------------------------------------------------
step "9/11  Vault shell helpers"
# ---------------------------------------------------------------------------
# Written outside the repo so they are never committed, then sourced from
# your shell rc inside a marked block that can be rewritten on re-run.
#
# These are shell functions, not aliases: an alias cannot take a file
# argument, cannot loop over the inventory, and cannot skip files that are
# already in the target state.
cat > "$VAULT_ALIASES" <<'ALIASES_EOF'
# ansible-infra vault helpers — generated by setup.sh, safe to regenerate.
#
#   ansible-un      UNLOCK: decrypt every vault file under inventory/
#   ansible-lo      LOCK:   encrypt every vault file under inventory/
#   ansible-st      STATUS: show which vault files are locked
#   ansible-vault-doctor  diagnose which password file each vault uses
#
#   vault-view FILE   read one file without writing plaintext to disk
#   vault-edit FILE   edit one file in $EDITOR, re-encrypts on save
#   vault-rekey FILE  change the vault password on one file
#
# ansible-un and ansible-lo operate on the whole repo, find the repo root
# themselves, and skip files already in the target state. ansible-vault
# errors out on a double decrypt or double encrypt, so skipping is what
# makes them safe to run twice.
#
# Each env has its own password file, resolved per vault file from its
# path. See _vault_pw_for below.

# Password file for a GIVEN vault file. Each environment has its own
# password, so a single global password file is wrong the moment a second
# env exists: homelab's password cannot decrypt work's vault.
#
# Resolution, first match wins:
#   1. $VAULT_ENV forced by the caller
#   2. env name parsed out of the path (inventory/group_vars/<env>/...)
#   3. $ANSIBLE_VAULT_PASSWORD_FILE
#   4. the only ~/.ansible/vault_pass_* file, if there is exactly one
_vault_pw_for() {
    local f="$1" env="" c count last=""

    if [ -n "${VAULT_ENV:-}" ]; then
        env="$VAULT_ENV"
    else
        # inventory/group_vars/<env>/vault.yml  ->  <env>
        case "$f" in
            */group_vars/*) env="${f#*/group_vars/}"; env="${env%%/*}" ;;
        esac
        # 'all' is shared and has no password of its own.
        [ "$env" = "all" ] && env=""
    fi

    if [ -n "$env" ] && [ -f "${HOME}/.ansible/vault_pass_${env}" ]; then
        printf '%s' "${HOME}/.ansible/vault_pass_${env}"
        return 0
    fi

    if [ -n "${ANSIBLE_VAULT_PASSWORD_FILE:-}" ] && [ -f "${ANSIBLE_VAULT_PASSWORD_FILE}" ]; then
        printf '%s' "${ANSIBLE_VAULT_PASSWORD_FILE}"
        return 0
    fi

    # Only fall back to a lone password file. Picking the first of several
    # is how you get a confusing "decryption failed" on the wrong env.
    count=0
    for c in "${HOME}"/.ansible/vault_pass_*; do
        [ -f "$c" ] && { count=$((count + 1)); last="$c"; }
    done
    if [ "$count" -eq 1 ]; then
        printf '%s' "$last"
        return 0
    fi

    return 1
}

# Repo root, so the helpers work from any subdirectory.
_vault_root() {
    git rev-parse --show-toplevel 2>/dev/null && return 0
    [ -f ansible.cfg ] && { pwd; return 0; }
    return 1
}

# Every vault file in this repo. Matches vault.yml and vault_*.yml at any
# depth under inventory/, which covers group_vars and host_vars.
_vault_files() {
    local root
    root="$(_vault_root)" || return 1
    find "$root/inventory" \
        -type f \( -name 'vault.yml' -o -name 'vault_*.yml' -o -name 'vault.yaml' \) \
        2>/dev/null | sort
}

_vault_is_locked() {
    head -c 14 "$1" 2>/dev/null | grep -q '$ANSIBLE_VAULT'
}

# Run ansible-vault with EXACTLY ONE identity.
#
# ansible.cfg already sets vault_password_file. Passing
# --vault-password-file as well creates a second, equally unlabelled
# identity, and ansible-vault then refuses to encrypt:
#
#   ERROR! The vault-ids default,default are available to encrypt.
#          Specify the vault-id to encrypt with --encrypt-vault-id
#
# Decrypt is unaffected because it simply tries each identity until one
# works, which is why unlock succeeded while lock failed.
#
# The fix is to pass the password through the environment instead of the
# command line. ANSIBLE_VAULT_PASSWORD_FILE overrides the ansible.cfg
# value rather than adding to it, so only one identity ever exists.
# ANSIBLE_VAULT_IDENTITY_LIST is cleared for the same reason.
_vault_exec() {
    local pw="$1" action="$2" file="$3"
    if [ -n "$pw" ]; then
        ANSIBLE_VAULT_PASSWORD_FILE="$pw" \
        ANSIBLE_VAULT_IDENTITY_LIST="" \
        ansible-vault "$action" "$file"
    else
        # No resolved password: let ansible.cfg apply on its own.
        ansible-vault "$action" "$file"
    fi
}

_vault_bulk() {
    local action="$1" want_locked="$2" verb="$3"
    local pw args files f root rel err n=0 skipped=0 rc=0

    root="$(_vault_root)" || { echo "not inside the ansible repo" >&2; return 1; }
    files="$(_vault_files)"
    [ -n "$files" ] || { echo "no vault files found under inventory/" >&2; return 1; }

    # cd to the repo root so ansible.cfg is picked up. Without it, running
    # from a subdirectory silently loses vault_password_file.
    local prev; prev="$PWD"; cd "$root" || return 1

    while IFS= read -r f; do
        [ -n "$f" ] || continue
        rel="${f#"$root/"}"

        if _vault_is_locked "$f"; then
            [ "$want_locked" = "yes" ] && { skipped=$((skipped + 1)); continue; }
        else
            [ "$want_locked" = "no" ] && { skipped=$((skipped + 1)); continue; }
        fi

        pw="$(_vault_pw_for "$f")" || pw=""

        # Capture stderr instead of discarding it. A silent FAILED tells
        # you nothing; the ansible-vault message names the actual problem.
        if err="$(_vault_exec "$pw" "$action" "$f" 2>&1)"; then
            echo "  ${verb}  ${rel}"
            n=$((n + 1))
        else
            echo "  FAILED     ${rel}" >&2
            echo "${err}" | sed 's/^/             /' >&2
            [ -n "${pw:-}" ] && echo "             password file: ${pw}" >&2

            # Point at the fix for the failures that actually happen.
            case "$err" in
                *"already encrypted"*)
                    echo "             already locked — nothing to do" >&2 ;;
                *"not vault encrypted"*)
                    echo "             already unlocked — nothing to do" >&2 ;;
                *"available to encrypt"*|*"encrypt-vault-id"*)
                    echo "             more than one vault identity is active;" >&2
                    echo "             ansible.cfg and the environment are both supplying one" >&2 ;;
                *"was not found"*|*"could not be found"*)
                    echo "             password file missing — check ~/.ansible/vault_pass_*" >&2 ;;
                *"Permission denied"*)
                    echo "             fix ownership:  chown -R \$USER:\$USER inventory/" >&2 ;;
            esac
            rc=1
        fi
    done <<EOF
$files
EOF

    cd "$prev" || true
    echo "  ${n} changed, ${skipped} already in state"
    return $rc
}

# UNLOCK — decrypt everything. Plaintext secrets land in the working tree.
ansible-un() {
    _vault_bulk decrypt no "decrypted" || return $?
    echo
    echo "  Vault files are now PLAINTEXT in the working tree."
    echo "  Run ansible-lo before committing. The pre-commit hook blocks it otherwise."
}

# LOCK — encrypt everything. Run before every commit.
ansible-lo() {
    _vault_bulk encrypt yes "encrypted"
}

# Which password file each vault resolves to, and whether it works.
# Run this first whenever ansible-un or ansible-lo reports FAILED.
ansible-vault-doctor() {
    local files f root rel pw
    root="$(_vault_root)" || { echo "not inside the ansible repo" >&2; return 1; }
    ( cd "$root" || return 1
      echo "  password files present:"
      ls -1 "${HOME}"/.ansible/vault_pass_* 2>/dev/null | sed 's/^/    /' \
          || echo "    none"
      echo
      grep -E '^\s*(vault_password_file|vault_identity_list)' ansible.cfg \
          | sed 's/^/  ansible.cfg: /' || echo "  ansible.cfg: no vault password configured"
      echo
      _vault_files | while IFS= read -r f; do
          [ -n "$f" ] || continue
          rel="${f#"$root/"}"
          if pw="$(_vault_pw_for "$f")"; then
              if _vault_is_locked "$f"; then
                  if _vault_exec "$pw" view "$f" >/dev/null 2>&1; then
                      echo "  OK         ${rel}  <- ${pw##*/}"
                  else
                      echo "  WRONG PW   ${rel}  <- ${pw##*/}"
                  fi
              else
                  echo "  plaintext  ${rel}  <- ${pw##*/}"
              fi
          else
              echo "  NO PW      ${rel}  (set VAULT_ENV or create ~/.ansible/vault_pass_<env>)"
          fi
      done )
}

# STATUS — what is locked right now.
ansible-st() {
    local files f root
    root="$(_vault_root)" || { echo "not inside the ansible repo" >&2; return 1; }
    files="$(_vault_files)"
    [ -n "$files" ] || { echo "  no vault files found under inventory/"; return 0; }
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        if _vault_is_locked "$f"; then
            echo "  locked      ${f#"$root/"}"
        else
            echo "  PLAINTEXT   ${f#"$root/"}"
        fi
    done <<EOF
$files
EOF
}

# Single-file helpers. vault-view and vault-edit never leave plaintext on
# disk, so prefer them over ansible-un for a quick read or a small change.
_vault_one() {
    local action="$1"; shift
    [ $# -gt 0 ] || { echo "usage: vault-${action} FILE" >&2; return 2; }
    local pw
    pw="$(_vault_pw_for "$1")" || pw=""
    _vault_exec "$pw" "$action" "$1"
}

vault-view()  { _vault_one view  "$@"; }
vault-edit()  { _vault_one edit  "$@"; }
vault-rekey() { _vault_one rekey "$@"; }
ALIASES_EOF

chmod 600 "$VAULT_ALIASES"
ok "wrote ${VAULT_ALIASES}"

# Source it from whichever rc files exist. The markers make the block
# idempotent: re-running setup.sh replaces it instead of appending again.
SOURCE_LINE="[ -f \"${VAULT_ALIASES}\" ] && . \"${VAULT_ALIASES}\""
for RC in "${HOME}/.bashrc" "${HOME}/.zshrc"; do
    [ -f "$RC" ] || continue
    if grep -q '# >>> ansible-infra vault helpers >>>' "$RC"; then
        ok "$(basename "$RC") already sources the helpers"
    else
        {
            echo ""
            echo "# >>> ansible-infra vault helpers >>>"
            echo "$SOURCE_LINE"
            echo "# <<< ansible-infra vault helpers <<<"
        } >> "$RC"
        ok "added source block to $(basename "$RC")"
    fi
done

# Make them available in the current shell too, if this script was sourced
# rather than executed. Harmless either way.
# shellcheck disable=SC1090
. "$VAULT_ALIASES" 2>/dev/null || true

# ---------------------------------------------------------------------------
step "10/11  Inventory and playbooks"
# ---------------------------------------------------------------------------
ansible-inventory --list >/dev/null 2>&1 || die "inventory failed to parse"
ok "inventory parses"

HOST_COUNT="$(ansible all --list-hosts 2>/dev/null | grep -cE '^[[:space:]]+[^[:space:]]' || true)"
[ "${HOST_COUNT:-0}" -gt 0 ] || warn "inventory contains no hosts"

for PB in site.yml apps.yml reset.yml; do
    [ -f "$PB" ] || { warn "${PB} not found"; continue; }
    ansible-playbook --syntax-check "$PB" >/dev/null 2>&1 || die "${PB} failed syntax check"
    ok "${PB} syntax ok"
done

# Readable diffs for encrypted vaults — otherwise every change is one
# opaque ciphertext blob.
if git rev-parse --git-dir >/dev/null 2>&1; then
    if ! git config --get diff.ansible-vault.textconv >/dev/null 2>&1; then
        git config diff.ansible-vault.textconv "ansible-vault view"
        ok "configured vault diff driver"
    fi
fi

# ---------------------------------------------------------------------------
step "11/11  Host reachability"
# ---------------------------------------------------------------------------
# Non-fatal — VMs legitimately may not exist yet during a rebuild.
if ansible all -m ping -o >/dev/null 2>&1; then
    ok "all inventory hosts reachable"
else
    warn "not all hosts reachable — expected if VMs are not provisioned yet"
    warn "  check with: ansible all -m ping"
fi

# ---------------------------------------------------------------------------
if [ "$WARN_COUNT" -gt 0 ]; then
    echo
    echo "${YLW}Completed with ${WARN_COUNT} warning(s). Review them above.${NC}"
fi

cat <<EOF

${GRN}==========================================
 Control machine ready
==========================================${NC}

  Dry run (do this first):
    ansible-playbook site.yml --check --diff

  Full deploy (provision + OS + apps):
    ansible-playbook site.yml

  Applications only:
    ansible-playbook apps.yml

  Single environment:
    ansible-playbook site.yml --limit homelab

  Verify reachability:
    ansible all -m ping -o

  DESTRUCTIVE — wipes one service, moves appdata aside first:
    ansible-playbook reset.yml -e reset_service=nextcloud

  Vault helpers (after restarting your shell):
    ansible-un      unlock: decrypt every vault file under inventory/
    ansible-lo      lock:   encrypt every vault file under inventory/
    ansible-st      status: show which vault files are locked

    Single file, no plaintext on disk:
      vault-view inventory/group_vars/homelab/vault.yml
      vault-edit inventory/group_vars/homelab/vault.yml

    Non-default env:  VAULT_ENV=work ansible-un
    If a file reports FAILED:  ansible-vault-doctor

  Run the commit hooks manually:
    pre-commit run --all-files

  Run the push hooks manually:
    pre-commit run --hook-stage pre-push --all-files

  Bypass hooks in an emergency (use sparingly):
    git commit --no-verify

  If pipx was just installed, restart your shell or: source ~/.bashrc

EOF