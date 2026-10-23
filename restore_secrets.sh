#!/usr/bin/env bash
# Undo backup_secrets.sh: decrypt config.age, ssh.age and gpg.age from the current folder,
# put the .conf/.json files back in ~/.config, unpack ~/.ssh, import the GPG keys, and fix
# permissions.
# Missing .age files are skipped. The decrypted zips and key export are shredded afterwards.
# Each step is logged with a timestamp, and long steps report progress every 10s.
#
#   ./restore_secrets.sh   # asks for the passphrase once, used for all three files
#
# Files in the backup overwrite the same files under ~; other existing files are kept.
set -euo pipefail

umask 077
in_dir=$PWD
work=$(mktemp -d -t restore_secrets.XXXXXX)   # decrypted plaintext (mode 700), shredded on exit
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

names=()
for name in config ssh gpg; do
    if [[ -f $in_dir/$name.age ]]; then names+=("$name"); else log "$name.age not found, skipping" >&2; fi
done
(( ${#names[@]} )) || { log "Nothing to restore in $in_dir" >&2; exit 1; }

existing=()
for name in config ssh; do
    if [[ " ${names[*]} " == *" $name "* && -d ~/.$name ]]; then existing+=("~/.$name"); fi
done
if (( ${#existing[@]} )); then
    read -rp "Overwrite matching files in ${existing[*]}? [y/N] " answer < /dev/tty
    [[ $answer == [yY]* ]] || { echo "Aborted" >&2; exit 1; }
fi

# Held only in this shell's memory (not exported, never on disk) until the script exits.
read -rsp "Passphrase: " passphrase < /dev/tty; echo

# age_pty CMD: run the age command line CMD, typing the passphrase in. Same trick as
# backup_secrets.sh: age 1.0 only reads passphrases from a terminal, so give it one with
# script and discard the pty's output, which may echo the passphrase.
age_pty() {
    printf '%s\n' "$passphrase" | script -qec "$1" /dev/null > /dev/null
}

# decrypt NAME OUTPUT: age-decrypt NAME.age to OUTPUT
decrypt() {
    log "Decrypting $1.age ($(size "$in_dir/$1.age"))"
    watch_run "$2" age_pty "$(printf '%q ' age -d -o "$2" "$in_dir/$1.age")" \
        || { log "Could not decrypt $1.age (wrong passphrase?)" >&2; exit 1; }
}

# shred_file FILE: securely delete a decrypted file
shred_file() {
    log "Shredding $(basename "$1")"
    watch_run "" shred -uz "$1"
}

for name in "${names[@]}"; do
    case $name in
    config|ssh)
        decrypt "$name" "$work/$name.zip"
        log "Unpacking $name.zip into ~/.$name"
        watch_run "" unzip -qo "$work/$name.zip" -d ~
        if [[ $name == config ]]; then mapfile -t config_files < <(unzip -Z1 "$work/config.zip"); fi
        shred_file "$work/$name.zip"
        ;;
    gpg)
        decrypt gpg "$work/gpg.asc"
        mkdir -p ~/.gnupg && chmod 700 ~/.gnupg
        log "Importing GPG keys (gpg may be waiting for a key passphrase in a pinentry window)"
        gpg --import "$work/gpg.asc"
        # The keys are yours, so trust them ultimately again (the backup has no trust db).
        log "Marking the imported keys as ultimately trusted"
        gpg --show-keys --with-colons "$work/gpg.asc" \
            | awk -F: '/^sec/ {p=1; next} p && /^fpr/ {print $10 ":6:"; p=0}' \
            | gpg --import-ownertrust
        shred_file "$work/gpg.asc"
        ;;
    esac
done

# ssh refuses keys and configs that others can read or write.
if [[ " ${names[*]} " == *" ssh "* ]]; then
    log "Fixing permissions in ~/.ssh"
    chmod 700 ~/.ssh
    find ~/.ssh -type d -exec chmod 700 {} +
    find ~/.ssh -type f -exec chmod 600 {} +
    find ~/.ssh -type f -name '*.pub' -exec chmod 644 {} +
fi
# zip keeps each file's own mode; just make sure the restored files aren't writable by others.
if [[ " ${names[*]} " == *" config "* ]]; then
    log "Fixing permissions of the ${#config_files[@]} restored ~/.config files"
    (cd ~ && chmod go-w -- "${config_files[@]}")
fi

log "Restored ${names[*]} in ${SECONDS}s"
