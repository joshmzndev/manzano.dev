#!/usr/bin/env bash
# Encrypt the ~/.config/*.conf and ~/.config/*.json files (top level only), ~/.ssh and the GPG
# keyring with age (passphrase) into the current folder: config.age, ssh.age and gpg.age. The plaintext zips and key export are shredded afterwards.
# Each step is logged with a timestamp, and long steps report progress every 10s.
#
#   ./backup_secrets.sh   # asks for the passphrase once, used for all three files
#
# Restore with ./restore_secrets.sh from the folder holding the .age files.
set -euo pipefail

umask 077
out_dir=$PWD
work=$(mktemp -d -t backup_secrets.XXXXXX)   # zips and key export (mode 700), shredded on exit
hb_pid=

cleanup() {
    unset passphrase
    if [[ -n $hb_pid ]]; then kill "$hb_pid" 2>/dev/null || true; fi
    find "$work" -type f -exec shred -uz {} + 2>/dev/null || true
    rm -rf "$work"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

log() { printf '[%s] %s\n' "$(date +%T)" "$*"; }
size() { local s; s=$(du -sh "$1" 2>/dev/null | cut -f1); echo "${s:-0}"; }

# watch_run FILE CMD...: run CMD, logging the elapsed time (and FILE's size, unless FILE is
# empty) every 10s so a slow step can be told apart from a hung one.
watch_run() {
    local watch=$1 start=$SECONDS status=0; shift
    ( while sleep 10; do
        log "  ...still working, $((SECONDS - start))s${watch:+, $(size "$watch") written}"
    done ) &
    hb_pid=$!
    "$@" || status=$?
    kill "$hb_pid" 2>/dev/null; wait "$hb_pid" 2>/dev/null || true; hb_pid=
    log "  took $((SECONDS - start))s"
    return "$status"
}

# Held only in this shell's memory (not exported, never on disk) until the script exits.
read -rsp "Passphrase: " passphrase < /dev/tty; echo
read -rsp "Confirm passphrase: " confirm < /dev/tty; echo
[[ -n $passphrase ]] || { echo "Empty passphrase" >&2; exit 1; }
[[ $passphrase == "$confirm" ]] || { echo "Passphrases do not match" >&2; exit 1; }
unset confirm

# age_pty CMD: run the age command line CMD, typing the passphrase (plus confirmation) in.
# age 1.0 only reads passphrases from a terminal, so give it one with script. printf is a
# builtin, so the passphrase never shows up in a process list; the pty's output, which may
# echo it, is discarded.
age_pty() {
    printf '%s\n%s\n' "$passphrase" "$passphrase" | script -qec "$1" /dev/null > /dev/null
}

# encrypt PLAINTEXT NAME: age-encrypt PLAINTEXT to NAME.age, then shred PLAINTEXT
encrypt() {
    log "Encrypting $2.age from $(size "$1")"
    watch_run "$out_dir/$2.age" age_pty "$(printf '%q ' age -p -o "$out_dir/$2.age" "$1")" \
        || { log "age failed for $2.age" >&2; exit 1; }
    log "Shredding $(basename "$1")"
    watch_run "" shred -uz "$1"
}

# zip_up NAME DESCRIPTION PATH...: zip PATHs into NAME.zip and encrypt it to NAME.age. PATHs
# are relative to ~ so unzip -d ~ restores them; -y keeps symlinks as links.
zip_up() {
    local name=$1 what=$2; shift 2
    cd ~
    log "Zipping $what ($(du -csh "$@" | tail -1 | cut -f1))"
    watch_run "$work" zip -qry "$work/$name.zip" "$@"
    cd "$out_dir"
    encrypt "$work/$name.zip" "$name"
}

config_files=()
if [[ -d ~/.config ]]; then
    cd ~
    shopt -s nullglob
    config_files=(.config/*.conf .config/*.json)
    shopt -u nullglob
    cd "$out_dir"
fi
if (( ${#config_files[@]} )); then
    zip_up config "${#config_files[@]} .conf/.json files from ~/.config" "${config_files[@]}"
else
    log "No .conf or .json files in ~/.config, skipping" >&2
fi

if [[ -d ~/.ssh ]]; then zip_up ssh "~/.ssh" .ssh; else log "~/.ssh not found, skipping" >&2; fi

if [[ -n $(gpg --list-secret-keys 2>/dev/null) ]]; then
    # Secret key export includes the public keys.
    log "Exporting GPG keys (gpg may be waiting for a key passphrase in a pinentry window)"
    gpg --armor --export-secret-keys > "$work/gpg.asc"
    encrypt "$work/gpg.asc" gpg
else
    log "No GPG secret keys found, skipping" >&2
fi

log "Done in ${SECONDS}s:"
ls -sh "$out_dir"/*.age 2>/dev/null | sed "s#$out_dir/##"
