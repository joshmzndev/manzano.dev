#!/usr/bin/env bash
# Encrypted backups of local folders to noreply@tyas.tyc.edu.tw's Google Drive with rclone,
# plus `organize`, which files stray music/pictures/videos/documents into their home folders.
# Self-contained: download it into your home folder and run it.
#
#   cd ~ && curl -fsSLo backup.sh <URL> && chmod +x backup.sh
#   ./backup.sh setup     # rclone.conf (+ a commented .env template if there is none)
#   ./backup.sh check
#   DRY_RUN=1 ./backup.sh organize   # see what would move, then run it without DRY_RUN
#   ./backup.sh backup
#   ./backup.sh install   # systemd timer: backup at boot and every hour
#   (or without saving it: curl -fsSL <URL> | bash -s -- backup, uses ./.env)
#
# Settings are in CONFIG right below; `usage` lists the commands; README.md covers the
# Google-side setup.
set -euo pipefail

# Environment values are saved before the defaults below, so they can still override them.
declare -A ENV_IN=(); for k in $(compgen -e); do ENV_IN[$k]=${!k}; done

# ======================================== CONFIG ========================================
# Defaults. Every setting except BOT_EMAIL can be overridden by the same line in .env (next
# to this script, or BACKUP_ENV=/path/.env) or by an environment variable, which wins over
# .env. ~ is your home folder; relative paths are relative to the .env's folder.

readonly BOT_EMAIL=noreply@tyas.tyc.edu.tw   # Drive account. Fixed on purpose: no override.

# --- backup ---
GOOGLE_SERVICE_ACCOUNT_FILE=~/.secret/service_account.json   # service account key (keep it chmod 600)
RCLONE_CONFIG=~/.secret/rclone.conf   # written by setup; holds the encryption password + salt
REMOTE_DIR=encrypted-backup        # folder in the bot's Drive (used by setup only)
# Folders `backup` syncs, comma-separated. Each goes to current/NAME on Drive: NAME is the
# folder's name, or PATH:NAME. While this is the default list, missing folders are skipped.
# Most folders are mirrored, but ~/Music, ~/Pictures, ~/Videos and ~/Documents are only added
# to: a file deleted there stays in the backup (and in its directory.json) until `forget`.
# Rebuildable junk inside them is left out (FILTER_RULES below), and so is any folder holding
# a file named .nobackup or CACHEDIR.TAG.
BACKUP_DIRS=~/Documents,~/Videos,~/Music,~/Pictures,~/Desktop
# Your own rclone filter file (https://rclone.org/filtering/), checked before FILTER_RULES,
# e.g. "- *.mkv" or "+ keep.iso". Matching ignores case. Empty = none.
BACKUP_FILTER=
# Old versions (archive/<time>/) older than this many days are deleted for good after each
# backup. 0 = keep them forever.
ARCHIVE_KEEP_DAYS=90

# --- organize ---
# `organize` goes through every folder in ORGANIZE_ROOT except the BACKUP_DIRS, the four
# target folders and ORGANIZE_EXCLUDE (so e.g. ~/Downloads), and moves files by extension into
# ORGANIZE_ROOT/Music, /Pictures, /Videos or /Documents, keeping their subfolders. It never
# overwrites (adds " (1)"), and never enters hidden folders, git repos or ORGANIZE_SKIP.
# `organize PATH` goes through only PATH instead (even an excluded or backed-up folder).
# `tidy` is organize plus the four folders themselves: a file there of another category moves
# to that folder, and of each set of identical files in a folder one is kept (not named like
# a copy, then the oldest, then the shallowest) and the rest go to the Trash. Empty files
# aren't compared. Keep projects out of ~/Documents (e.g. on ~/Desktop or in an
# ORGANIZE_EXCLUDE folder): tidy would move their pictures etc. out.
# When ORGANIZE_LOOSE=1, every loose (not hidden) file directly in ORGANIZE_ROOT is moved
# too: by extension, and to Documents when no category fits. This script, its .env,
# rclone.conf and the service account key always stay put.
# Files changed in the last 10 minutes (maybe still downloading) are left alone. Subtitles
# (Movie.srt, Movie.en.srt) move with their video. .ts and .raw also mean other things
# (TypeScript, raw data), so they only move when `file` says they are a video / a picture.
# A file whose contents (sha256sum) already exist in the folder it's headed for (or that's a
# copy of another file being moved there, or that's only in the backup, which is checked on
# Drive first) goes to the Trash instead (restorable from the file manager; nothing is
# deleted). Each of the four folders keeps its files' checksums in
# its own directory.json, updated on every run; only new or changed files are hashed, so the
# first run reads everything once and can take a while for big folders. A directory.json
# that organize didn't write is left alone (and not used).
# Afterwards, empty folders in the organized folders are removed (checked empty first; a
# folder holding only hidden files isn't empty). The top-level folder itself goes too if it
# ends up empty, unless it's in ORGANIZE_KEEP_EMPTY or it's the PATH given to organize.
ORGANIZE_ROOT=~
ORGANIZE_ON_BACKUP=0          # 1 = run organize at the start of every backup
ORGANIZE_SKIP=snap,Templates,Public,bin,node_modules,venv   # folder names never entered
ORGANIZE_EXCLUDE=~/Desktop    # folders (paths, comma-separated) never organized
ORGANIZE_KEEP_EMPTY=Downloads # top-level folders kept even when organize empties them
ORGANIZE_LOOSE=1              # 1 = also organize every loose file directly in ORGANIZE_ROOT
MUSIC_EXTS="mp3 flac wav ogg oga opus m4a aac wma aiff aif aifc ape wv dsf dff m4b mka amr tta
    mpc caf mid midi"
# Camera RAW: dng cr2 and the rest of the second line.
PICTURES_EXTS="jpg jpeg jpe png gif bmp webp tif tiff heic heif avif jxl psd xcf kra
    dng cr2 cr3 crw nef nrw arw srf sr2 orf rw2 raf pef srw 3fr fff iiq x3f rwl mrw erf mef mos kdc dcr"
VIDEOS_EXTS="mp4 m4v mkv mov avi wmv webm flv mpg mpeg 3gp 3g2 mts m2ts vob ogv divx rm rmvb asf mxf"
# Left out on purpose, as they're as often part of a project or an app: txt md csv json xml
# conf svg, key (Keynote, but also TLS keys), archives, disk images, installers, scripts.
DOCUMENTS_EXTS="pdf doc docx odt rtf xls xlsx ods ppt pptx odp odg odf pages numbers djvu xps oxps
    epub mobi azw3 ics vcf pub"

# --- schedule + logs ---
# `install` adds a systemd user timer that runs the backup BOOT_DELAY after boot and then
# every hour (on the hour). Only one backup runs at a time: a run that's due while another
# is still going waits for it to finish, then starts.
BOOT_DELAY=2min               # systemd time span, e.g. 30s, 5min
SCHEDULE=hourly               # systemd OnCalendar, e.g. hourly, *:0/30, daily
STATE_DIR=~/.rclone_backup    # hidden folder: logs/ (one file per day) and the lock file
LOG_KEEP_DAYS=30              # older log files are deleted
# ====================================== END CONFIG ======================================

CONFIG_KEYS=(GOOGLE_SERVICE_ACCOUNT_FILE RCLONE_CONFIG REMOTE_DIR BACKUP_DIRS BACKUP_FILTER
    ARCHIVE_KEEP_DAYS ORGANIZE_ROOT ORGANIZE_ON_BACKUP ORGANIZE_SKIP
    MUSIC_EXTS PICTURES_EXTS VIDEOS_EXTS DOCUMENTS_EXTS ORGANIZE_EXCLUDE ORGANIZE_KEEP_EMPTY
    ORGANIZE_LOOSE
    BOOT_DELAY SCHEDULE STATE_DIR LOG_KEEP_DAYS)
UNIT=rclone-backup            # systemd unit name (.service + .timer)
CATEGORIES=(Music Pictures Videos Documents)   # target folder = name, extensions = NAME_EXTS
SUB_EXTS="srt ass ssa vtt sub idx"   # subtitles: only moved together with their video
DEFAULT_BACKUP_DIRS=$BACKUP_DIRS

# rclone filter rules for backup/sync, inside each backed-up folder (first match wins). Only
# things that can be rebuilt or downloaded again. Files they match that are already on Drive
# stay in current/: sync doesn't delete excluded files.
FILTER_RULES='
# this script (it sits in ~/Desktop/Bot)
- backup.sh
# dependency and build folders
- node_modules/**
- __pycache__/**
- *.py[co]
- .venv/**
- venv/**
- .tox/**
- .mypy_cache/**
- .pytest_cache/**
- .gradle/**
- .next/**
# partial downloads, temp files, editor swap/backup files, office lock files
- *.part
- *.crdownload
- *.partial
- *.!qB
- *.tmp
- *~
- *.swp
- *.swo
- .~lock.*#
# disk and VM images
- *.{iso,img,qcow2,vdi,vmdk,vhd,vhdx}
'

die() { echo "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
Usage: backup.sh COMMAND

  setup              write rclone.conf (asks for the encryption password; a random salt
                     is generated and printed once), and a commented .env if there is none
  check              key + delegation (as noreply@), then the rclone remotes
  backup             sync every folder in BACKUP_DIRS (default: ~/Documents, ~/Videos,
                     ~/Music, ~/Pictures, ~/Desktop), then delete archive/ versions older
                     than ARCHIVE_KEEP_DAYS; runs organize first if ORGANIZE_ON_BACKUP=1
  organize [PATH]    move music/pictures/videos/documents from the other folders in ~
                     (e.g. ~/Downloads), or only from PATH, into ~/Music, ~/Pictures,
                     ~/Videos, ~/Documents; with ORGANIZE_LOOSE=1 (and no PATH), every
                     loose file in ~ too (Documents when no category fits).
  tidy               organize, and also sort out ~/Music, ~/Pictures, ~/Videos, ~/Documents
                     themselves: files of another category move to their folder, and
                     duplicates within a folder go to the Trash (one copy is kept)
  formats [DIR]      count files and size per extension under DIR (default ~), for the
                     extensions organize doesn't handle (not in any *_EXTS list)
  sync SRC [NAME]    mirror SRC to current/NAME (NAME = SRC's folder name);
                     changed/deleted files move to archive/<time>/NAME. ~/Music,
                     ~/Pictures, ~/Videos, ~/Documents are only added to: files deleted
                     there stay in the backup until you `forget` them
  ls [PATH]          list the backup (decrypted names), e.g. ls current
  restore PATH DEST  copy PATH (e.g. current/data) back to local DEST
  restore            (no arguments) create ~/Music, ~/Pictures, ~/Videos, ~/Documents if
                     missing and put each one's directory.json from the backup inside
  forget PATH        really remove PATH (e.g. current/Pictures/old.jpg) from the backup:
                     it moves to archive/<time>/ and is deleted after ARCHIVE_KEEP_DAYS
  install            systemd user timer: backup BOOT_DELAY after boot + every hour
  uninstall          remove that timer
  status             timer state + the end of today's log

Settings: CONFIG at the top of the script; override any of them in .env or the environment.
DRY_RUN=1: sync/backup/organize/tidy/restore/forget only show what they would do.
backup/organize/sync log to STATE_DIR/logs/ (and the terminal, when there is one).
EOF
}

# --- config loading ---------------------------------------------------------------------

if [[ -f ${BASH_SOURCE[0]:-} ]]; then
    HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
else
    HERE=$PWD   # piped from curl
fi
SELF="$HERE/$(basename "${BASH_SOURCE[0]:-backup.sh}")"
ENV_FILE=$(realpath -m "${BACKUP_ENV:-$HERE/.env}")
ENV_DIR=$(dirname "$ENV_FILE")

# Relative paths are relative to the .env's folder; ~ is expanded.
abspath() {
    local p=${1/#\~/$HOME}
    [[ $p == /* ]] || p="$ENV_DIR/$p"
    realpath -m "$p"
}

trim() { local s=${1#"${1%%[![:space:]]*}"}; printf %s "${s%"${s##*[![:space:]]}"}"; }

# Parsed, not sourced: only CONFIG_KEYS are read, nothing in .env is executed.
load_env() {
    local line k v
    if [[ -f $ENV_FILE ]]; then
        while IFS= read -r line || [[ -n $line ]]; do
            line=${line%$'\r'}
            [[ $line =~ ^[[:space:]]*(export[[:space:]]+)?([A-Z_]+)[[:space:]]*=[[:space:]]*(.*)$ ]] || continue
            k=${BASH_REMATCH[2]} v=${BASH_REMATCH[3]}
            # Quoted: taken as is. Unquoted: a " # comment" (as on the CONFIG lines) is dropped.
            if [[ $v =~ ^\"(.*)\"[[:space:]]*(#.*)?$ || $v =~ ^\'(.*)\'[[:space:]]*(#.*)?$ ]]; then
                v=${BASH_REMATCH[1]}
            else
                if [[ $v == \#* ]]; then v=
                elif [[ $v =~ ^(.*[^[:space:]])[[:space:]]+#.*$ ]]; then v=${BASH_REMATCH[1]}
                fi
                v=$(trim "$v")
            fi
            [[ " ${CONFIG_KEYS[*]} " == *" $k "* ]] && printf -v "$k" %s "$v"
        done <"$ENV_FILE"
    fi
    for k in "${CONFIG_KEYS[@]}"; do
        [[ -v ENV_IN[$k] ]] && printf -v "$k" %s "${ENV_IN[$k]}"
    done
    return 0
}
load_env

KEY=$(abspath "$GOOGLE_SERVICE_ACCOUNT_FILE")
export RCLONE_CONFIG; RCLONE_CONFIG=$(abspath "$RCLONE_CONFIG")
STATE_DIR=$(abspath "$STATE_DIR") LOG_DIR=$(abspath "$STATE_DIR/logs")
# Empty BACKUP_DIRS = the default list.
BACKUP_DIRS=${BACKUP_DIRS:-$DEFAULT_BACKUP_DIRS}
DEFAULT_DIRS=; [[ $BACKUP_DIRS == "$DEFAULT_BACKUP_DIRS" ]] && DEFAULT_DIRS=1

# BACKUP_DIRS -> BK_SRC (absolute paths) and BK_NAME (Drive folder names, may be empty).
BK_SRC=() BK_NAME=()
IFS=, read -ra _entries <<<"$BACKUP_DIRS"
for _e in "${_entries[@]}"; do
    _e=$(trim "$_e")
    [[ -n $_e ]] || continue
    BK_SRC+=("$(abspath "${_e%%:*}")")
    if [[ $_e == *:* ]]; then BK_NAME+=("${_e#*:}"); else BK_NAME+=(""); fi
done
unset _entries _e

# --- logs + lock ------------------------------------------------------------------------

# Appends this run's output to STATE_DIR/logs/<date>.log (also shown on a terminal).
start_log() {
    (umask 077; mkdir -p "$LOG_DIR"; touch "$LOG_DIR/$(date +%F).log")
    find "$LOG_DIR" -name '*.log' -mtime +"$LOG_KEEP_DAYS" -delete 2>/dev/null || true
    local log="$LOG_DIR/$(date +%F).log"
    if [[ -t 1 ]]; then exec > >(tee -a "$log") 2>&1; else exec >>"$log" 2>&1; fi
    echo "== $(date '+%F %T') backup.sh $*"
}

# One backup/organize at a time: wait for a running one to finish first.
LOCKED=
lock() {
    [[ -z $LOCKED ]] || return 0
    (umask 077; mkdir -p "$STATE_DIR"; touch "$STATE_DIR/backup.lock")
    exec 9>>"$STATE_DIR/backup.lock"
    if ! flock -n 9; then
        echo "== $(date '+%F %T') another backup is running; waiting for it to finish"
        flock 9
    fi
    LOCKED=1
}

# --- rclone -----------------------------------------------------------------------------

# Every call pins the account, scope and key on the command line, which rclone ranks above
# the config file and RCLONE_* env vars: an edited rclone.conf can't make it act as anyone else.
rc() {
    [[ -f $RCLONE_CONFIG ]] || die "No $RCLONE_CONFIG: run setup first."
    rclone --drive-impersonate "$BOT_EMAIL" --drive-scope drive \
        --drive-service-account-file "$KEY" "$@"
}

need() {
    command -v rclone >/dev/null || die "rclone is not installed: run setup, or https://rclone.org/install/"
    [[ -f $KEY ]] || die "No service account key at $KEY (set GOOGLE_SERVICE_ACCOUNT_FILE in $ENV_FILE)."
}

# chmod 600 the key and rclone.conf, and 700 their folders (e.g. ~/.secret). Folders that
# hold more than secrets (home, the script's own) are left as they are.
make_private() {
    local f d
    for f in "$KEY" "$RCLONE_CONFIG"; do
        [[ -e $f ]] || continue
        chmod 600 "$f"
        d=$(dirname "$f")
        [[ $d == "$HOME" || $d == "$HERE" || $d == / ]] || chmod 700 "$d"
    done
}

ask() { local a; read -rp "$1 [y/N] " a </dev/tty; [[ $a == [yY]* ]]; }

write_env_template() {
    (umask 077; cat >"$ENV_FILE" <<'EOF'
# backup.sh overrides. Defaults and explanations are in CONFIG at the top of the
# script; uncomment or copy a line from there to change it. Relative paths are relative to
# this file's folder.

#GOOGLE_SERVICE_ACCOUNT_FILE=service_account.json
#BACKUP_DIRS=~/Documents,~/Videos,~/Music,~/Pictures,~/Desktop
#ORGANIZE_ON_BACKUP=1
#ORGANIZE_SKIP=snap,Templates,Public,bin,node_modules,venv
#ORGANIZE_EXCLUDE=~/Desktop
#ORGANIZE_LOOSE=0
EOF
    )
    echo "Wrote $ENV_FILE (all defaults, commented out)."
}

setup() {
    [[ -f $ENV_FILE ]] || write_env_template
    if ! command -v rclone >/dev/null; then
        ask "rclone is not installed. Install it now with rclone.org/install.sh (sudo)?" \
            || die "Install rclone (v1.53+): https://rclone.org/install/"
        curl -fsSL https://rclone.org/install.sh | sudo bash
    fi
    need
    make_private
    [[ -e $RCLONE_CONFIG ]] && die "$RCLONE_CONFIG already exists. It holds the encryption
password: only delete it to start a new, empty backup."
    local pw pw2 salt
    read -rsp "Encryption password: " pw </dev/tty; echo
    read -rsp "Again: " pw2 </dev/tty; echo
    [[ -n $pw && $pw == "$pw2" ]] || die "Passwords are empty or don't match."
    salt=$(head -c 32 /dev/urandom | base64 | tr -d '\n')
    (umask 077; mkdir -p "$(dirname "$RCLONE_CONFIG")"; cat >"$RCLONE_CONFIG" <<EOF
[gdrive]
type = drive
scope = drive
service_account_file = $KEY
impersonate = $BOT_EMAIL

[gcrypt]
type = crypt
remote = gdrive:$REMOTE_DIR
filename_encryption = standard
directory_name_encryption = true
password = $(printf %s "$pw" | rclone obscure -)
password2 = $(printf %s "$salt" | rclone obscure -)
EOF
    )
    make_private
    cat <<EOF
Wrote $RCLONE_CONFIG (mode 600). Backups go to $BOT_EMAIL's Drive, folder $REMOTE_DIR/.

Save BOTH of these somewhere off this server and off Google (e.g. a password manager).
Without them the backup can never be decrypted:
  password:            (the one you typed)
  password2 (salt):    $salt
Or keep a copy of rclone.conf itself: \`rclone reveal\` recovers both from it.

Next: $SELF check
EOF
}

# Checks the delegation the way rclone signs in and that Drive says we are noreply@.
# Needs google-api-python-client + google-auth; skipped (rclone checks still run) without them.
check_delegation() {
    local py=${PYTHON:-python3}
    if ! "$py" -c 'import google.oauth2.service_account, googleapiclient.discovery' 2>/dev/null; then
        echo "  [skip] delegation check: pip install google-api-python-client google-auth"
        return 0
    fi
    KEY_FILE=$KEY "$py" - <<'PY'
import os, sys
from google.oauth2 import service_account
from googleapiclient.discovery import build

BOT_EMAIL = "noreply@tyas.tyc.edu.tw"
# The scope rclone requests with `scope = drive`. It must be authorized for the service
# account's client ID in admin.google.com (Security > Access and data control > API
# controls > Domain-wide delegation), or every call fails with "unauthorized_client".
SCOPES = ["https://www.googleapis.com/auth/drive"]
gb = lambda n: f"{int(n) / 1e9:.1f} GB"

print(f"Key file: {os.environ['KEY_FILE']}\nActing as: {BOT_EMAIL}\n")
try:
    creds = service_account.Credentials.from_service_account_file(
        os.environ["KEY_FILE"], scopes=SCOPES).with_subject(BOT_EMAIL)
    about = build("drive", "v3", credentials=creds, cache_discovery=False).about().get(
        fields="user(emailAddress),storageQuota").execute()
except Exception as e:  # report, don't trace
    print(f"  [FAIL] drive: {str(e).splitlines()[0][:160]}\n\nSee 'Troubleshooting' in README.md.")
    sys.exit(1)
email = about["user"]["emailAddress"]
if email.lower() != BOT_EMAIL:
    sys.exit(f"  [FAIL] drive: signed in as {email}, expected {BOT_EMAIL}")
quota = about.get("storageQuota", {})
limit = gb(quota["limit"]) if "limit" in quota else "pooled / unlimited"
print(f"  [ok]   drive: {email}, using {gb(quota.get('usage', 0))} of {limit}")
PY
}

check() {
    need
    check_delegation
    rc about gdrive:
    rc mkdir gcrypt:
    rc lsf gcrypt:
    echo "rclone remotes ok."
    echo "Backing up: ${BK_SRC[*]}"
    echo "Organize on backup: $([[ $ORGANIZE_ON_BACKUP == 1 ]] && echo on || echo off) (root $(abspath "$ORGANIZE_ROOT"))"
}

# Drive folder name (under current/) of DIR when it's in BACKUP_DIRS; fails otherwise.
backup_name() {
    local i
    for i in "${!BK_SRC[@]}"; do
        [[ ${BK_SRC[i]} == "$1" ]] && { printf %s "${BK_NAME[i]:-$(basename "$1")}"; return 0; }
    done
    return 1
}

# True when DIR is one of organize's four category folders.
is_category_dir() {
    local cat root
    root=$(abspath "$ORGANIZE_ROOT")
    for cat in "${CATEGORIES[@]}"; do [[ $1 == "$root/$cat" ]] && return 0; done
    return 1
}

# Mirrors SRC to current/NAME. The four category folders are only added to (rclone copy): a
# file deleted here stays in the backup, which organize's directory.json counts on (see
# `forget`). Either way, overwritten or deleted versions move to archive/<time>/NAME.
sync_() {
    need
    local src=${1:?usage: sync SRC [NAME]} name mode=sync
    [[ -d $src ]] || die "Not a folder: $src"
    lock
    name=${2:-$(basename "$(realpath "$src")")}
    is_category_dir "$(realpath "$src")" && mode=copy
    local filters=()
    if [[ -n $BACKUP_FILTER ]]; then filters+=(--filter-from "$(abspath "$BACKUP_FILTER")"); fi
    # --one-file-system: don't follow USB drives or FUSE/rclone mounts inside SRC.
    # --links: symlinks are stored as .rclonelink files (restore puts them back).
    rc "$mode" "$src" "gcrypt:current/$name" \
        "${filters[@]}" --filter-from - --ignore-case \
        --exclude-if-present .nobackup --exclude-if-present CACHEDIR.TAG \
        --one-file-system --links --skip-specials --fast-list \
        --backup-dir "gcrypt:archive/$(date +%F_%H%M%S)/$name" \
        --drive-stop-on-upload-limit \
        --stats 1m --stats-one-line -v ${DRY_RUN:+--dry-run} <<<"$FILTER_RULES"
}

# Deletes archive/<time> folders older than ARCHIVE_KEEP_DAYS, by the date in their name: a
# file's own date says nothing about when it was archived. Skips Drive's Trash, which would
# still count against the quota.
prune_archive() {
    [[ $ARCHIVE_KEEP_DAYS =~ ^[0-9]+$ ]] || { echo "ARCHIVE_KEEP_DAYS is not a number" >&2; return 1; }
    ((ARCHIVE_KEEP_DAYS > 0)) || return 0
    local cutoff dirs d
    cutoff=$(date -d "-$ARCHIVE_KEEP_DAYS days" +%F)
    rc mkdir gcrypt:archive
    dirs=$(rc lsf --dirs-only gcrypt:archive) || return 1
    while IFS= read -r d; do
        d=${d%/}
        [[ $d =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}_ && ${d:0:10} < $cutoff ]] || continue
        echo "== $(date '+%F %T') delete archive/$d (older than $ARCHIVE_KEEP_DAYS days)"
        [[ -n ${DRY_RUN:-} ]] && continue
        rc purge "gcrypt:archive/$d" --drive-use-trash=false || return 1
    done <<<"$dirs"
}

# Syncs each BACKUP_DIRS entry; keeps going past failures.
backup() {
    need
    [[ -f $RCLONE_CONFIG ]] || die "No $RCLONE_CONFIG: run setup first."
    lock
    local i src name failed=()
    if [[ $ORGANIZE_ON_BACKUP == 1 ]]; then
        organize || failed+=(organize)
    fi
    for i in "${!BK_SRC[@]}"; do
        src=${BK_SRC[i]} name=${BK_NAME[i]}
        if [[ ! -d $src ]]; then
            # A default folder that doesn't exist is normal (e.g. no ~/Videos); a listed one isn't.
            if [[ $DEFAULT_DIRS ]]; then echo "== skip $src (missing)"; continue; fi
            echo "Not a folder: $src" >&2; failed+=("$src"); continue
        fi
        echo "== $(date '+%F %T') $src -> current/${name:-$(basename "$src")}"
        sync_ "$src" "$name" || failed+=("$src")
    done
    prune_archive || failed+=(prune)
    ((${#failed[@]} == 0)) || die "Failed: ${failed[*]}"
    echo "== $(date '+%F %T') done"
}

# PATH, or "PATH (1).ext", "PATH (2).ext", ... whichever isn't taken yet, here or by a file
# that's only in the backup (which a new file there would replace), or by an earlier move in
# a dry run. A name without an extension gets " (1)" at the end.
taken() { [[ -e $1 || ${BACKUP_ONLY[$1]:-} == 1 || -n ${moved_in[$1]:-} ]]; }
unique_path() {
    local p=$1 base=$1 ext= n=1
    taken "$p" || { printf %s "$p"; return; }
    [[ ${p##*/} == ?*.* ]] && base=${p%.*} ext=.${p##*.}
    while taken "$base ($n)$ext"; do n=$((n + 1)); done
    printf %s "$base ($n)$ext"
}

# --- checksum index: directory.json in each of the four target folders -------------------
# {"folder", "updated", "file_count", "total_size", "algorithm", "note", "files": {...}}, with
# one line per file in "files": "path/relative/to/folder": {"name", "type", "local", "size",
# "modified", "mtime", "sha256"}. Written by hand, so read back line by line (no jq needed).
# A file that's gone from this computer keeps its entry ("local": false) while its folder is
# backed up, since the backup still has it (sync_ never deletes there; `forget` does).

INDEX_NAME=directory.json
INDEX_MARK='Written by backup.sh organize'

declare -A IDX_OLD=()                             # DIR/escaped path -> "size mtime sha256"
declare -A IDX_SIZE=() IDX_MTIME=() IDX_HASH=()   # absolute path -> value
declare -A BY_HASH=()                             # "Category sha256" -> absolute path
declare -A BACKUP_ONLY=()                         # absolute path -> 1 if only in the backup

file_hash() { local h; h=$(sha256sum <"$1") && printf %s "${h%% *}"; }

# Sets VAR to STRING escaped for a JSON string (only \ and "; control characters aren't written).
json_esc() { local s=${2//\\/\\\\}; printf -v "$1" %s "${s//\"/\\\"}"; }
# And back (\x01 stands in for \\ meanwhile: control characters are never written).
json_unesc() { local s=${2//\\\\/$'\x01'}; s=${s//\\\"/\"}; printf -v "$1" %s "${s//$'\x01'/\\}"; }

# True when DIR's directory.json is missing or one organize wrote (so it may be replaced).
idx_ours() { [[ ! -e $1/$INDEX_NAME ]] || grep -qF "$INDEX_MARK" -- "$1/$INDEX_NAME"; }

# PATH (in a category folder) SIZE MTIME HASH. Duplicates are looked up per category.
idx_add() {
    local cat=${1#"$ORG_ROOT"/}
    IDX_SIZE[$1]=$2 IDX_MTIME[$1]=$3 IDX_HASH[$1]=$4
    BY_HASH[${cat%%/*} $4]=$1
}

# Reads DIR/directory.json into IDX_OLD, keyed by DIR/ + the path as escaped in the file.
idx_load() {
    local dir=$1 line
    local re='^    "((\\.|[^"\\])*)": \{.*"size": ([0-9]+), .*"mtime": ([0-9]+), "sha256": "([0-9a-f]{64})"\},?$'
    [[ -f $dir/$INDEX_NAME ]] && idx_ours "$dir" || return 0
    while IFS= read -r line; do
        [[ $line =~ $re ]] &&
            IDX_OLD[$dir/${BASH_REMATCH[1]}]="${BASH_REMATCH[3]} ${BASH_REMATCH[4]} ${BASH_REMATCH[5]}"
    done <"$dir/$INDEX_NAME"
    return 0
}

# Indexes DIR's files: keeps entries whose size + mtime still match, hashes the rest.
idx_scan() {
    local dir=$1 rec size rest mtime rel key p h
    while IFS= read -r -d '' rec; do
        size=${rec%%/*} rest=${rec#*/}
        mtime=${rest%%/*} mtime=${mtime%.*} rel=${rest#*/}
        [[ $rel == "$INDEX_NAME" ]] && continue
        p=$dir/$rel key=$rel
        [[ $key == *[\\\"]* ]] && json_esc key "$key"
        if [[ ${IDX_OLD[$dir/$key]:-} == "$size $mtime "* ]]; then
            h=${IDX_OLD[$dir/$key]##* }
        else
            echo "  hashing ${p#"$ORG_ROOT"/}"
            h=$(file_hash "$p") || { echo "  [FAIL] could not read $p" >&2; continue; }
        fi
        idx_add "$p" "$size" "$mtime" "$h"
    done < <(find "$dir" -mindepth 1 -xdev -name '.*' -prune -o -type f -printf '%s/%T@/%P\0')
}

# After idx_scan: DIR's directory.json entries for files no longer here stay, as files only
# in the backup, when DIR is backed up (otherwise they're dropped).
idx_keep_backup_only() {
    local dir=$1 key rel p old prev
    backup_name "$dir" >/dev/null || return 0
    for key in "${!IDX_OLD[@]}"; do
        [[ $key == "$dir"/* ]] || continue
        json_unesc rel "${key#"$dir"/}"
        p=$dir/$rel
        [[ -z ${IDX_SIZE[$p]:-} && ! -e $p ]] || continue
        old=${IDX_OLD[$key]} prev=${BY_HASH[${dir##*/} ${old##* }]:-}
        idx_add "$p" "${old%% *}" "$(old=${old#* }; printf %s "${old%% *}")" "${old##* }"
        BACKUP_ONLY[$p]=1
        # A copy that's here beats one that's only in the backup.
        if [[ -n $prev ]]; then BY_HASH[${dir##*/} ${old##* }]=$prev; fi
    done
}

# True when backup-only PATH (in a category folder) really is in current/ on Drive with the
# indexed size. Returns 1 when it's not there, 2 when the backup can't be checked.
in_backup() {
    local p=$1 rel dir name out rc=0
    rel=${p#"$ORG_ROOT"/} dir=$ORG_ROOT/${rel%%/*}
    name=$(backup_name "$dir") || return 2
    command -v rclone >/dev/null && [[ -f $KEY && -f $RCLONE_CONFIG ]] || return 2
    out=$(rc lsf --files-only --format s "gcrypt:current/$name/${p#"$dir"/}" 2>/dev/null) || rc=$?
    case $rc in
        0) [[ -n $out && $out == "${IDX_SIZE[$p]}" ]] ;;
        3|4) return 1 ;;   # directory / file not found
        *) return 2 ;;
    esac
}

# Writes DIR/directory.json from the IDX_* entries under DIR. Paths with control characters
# aren't written (they're just hashed again next time).
idx_write() {
    local dir=$1 tmp p rel name ext here folder count=0 total=0 sep=
    local -a rels=()
    idx_ours "$dir" || { echo "  [WARN] $dir/$INDEX_NAME isn't organize's, not updating it" >&2; return 0; }
    for p in "${!IDX_SIZE[@]}"; do
        [[ $p == "$dir"/* && $p != *[[:cntrl:]]* ]] || continue
        [[ -e $p || ${BACKUP_ONLY[$p]:-} == 1 ]] && rels+=("${p#"$dir"/}")
    done
    tmp=$(mktemp "$dir/.$INDEX_NAME.XXXXXX")
    json_esc folder "$dir"
    {
        while IFS= read -r -d '' rel; do
            p=$dir/$rel name=${rel##*/} ext= here=true
            [[ $name == ?*.* ]] && ext=${name##*.} ext=${ext,,}
            [[ ${BACKUP_ONLY[$p]:-} == 1 ]] && here=false
            json_esc rel "$rel"; json_esc name "$name"; json_esc ext "$ext"
            printf '%s    "%s": {"name": "%s", "type": "%s", "local": %s, "size": %s, "modified": "%(%FT%T)T", "mtime": %s, "sha256": "%s"}' \
                "$sep" "$rel" "$name" "$ext" "$here" "${IDX_SIZE[$p]}" "${IDX_MTIME[$p]}" "${IDX_MTIME[$p]}" "${IDX_HASH[$p]}"
            sep=$',\n' count=$((count + 1)) total=$((total + ${IDX_SIZE[$p]}))
        done < <(((${#rels[@]})) && printf '%s\0' "${rels[@]}" | sort -z)
        [[ -n $sep ]] && echo
    } >"$tmp.files"
    {
        printf '{\n  "folder": "%s",\n  "updated": "%(%FT%T)T",\n' "$folder" -1
        printf '  "file_count": %s,\n  "total_size": %s,\n  "algorithm": "sha256",\n' "$count" "$total"
        printf '  "note": "%s. Sizes in bytes; paths relative to this folder; \\"local\\": false = only in the backup.",\n' "$INDEX_MARK"
        printf '  "files": {\n'; cat -- "$tmp.files"; printf '  }\n}\n'
    } >"$tmp"
    rm -f -- "$tmp.files"
    chmod 644 -- "$tmp"; mv -f -- "$tmp" "$dir/$INDEX_NAME"
}

# Moves FILE to the desktop Trash, so it can be restored from the file manager.
trash_file() {
    if command -v gio >/dev/null; then
        gio trash -- "$1" && [[ ! -e $1 ]]
    elif command -v trash-put >/dev/null; then
        trash-put -- "$1" && [[ ! -e $1 ]]
    else
        echo "  [FAIL] no gio or trash-put: install libglib2.0-bin or trash-cli" >&2; return 1
    fi
}

# .ts is TypeScript as often as MPEG-TS video, which has a 0x47 sync byte every 188 bytes.
is_mpegts() {
    local o
    for o in 0 188 376 564; do [[ $(od -An -tx1 -j$o -N1 -- "$1") == *47 ]] || return 1; done
}

# Subtitles next to VIDEO (Movie.srt, Movie.en.srt) follow it to DEST; alone they stay put.
move_subtitles() {
    local base=${1%.*} dest=$2 e s to
    for e in $SUB_EXTS; do
        for s in "$base.$e" "$base".*."$e"; do
            [[ -f $s ]] || continue
            to=$(unique_path "${dest%.*}${s#"$base"}")
            echo "  ${s#"$ORG_ROOT"/} -> ${to#"$ORG_ROOT"/}"
            [[ -n ${DRY_RUN:-} ]] && continue
            mv -n -- "$s" "$to" && [[ ! -e $s ]] || echo "  [FAIL] could not move $s" >&2
        done
    done
    return 0
}

# Removes empty folders under SRC, deepest first, and SRC itself unless KEEP_SRC is 1 or it's
# in ORGANIZE_KEEP_EMPTY. Only folders organize looks into (same PRUNE rules); each one is
# checked to have no entries at all (hidden ones count) right before rmdir, which also refuses
# non-empty.
remove_empty_dirs() {
    local src=$1 keep_src=$2 d keep_empty=() name
    shift 2
    IFS=, read -ra keep_empty <<<"$ORGANIZE_KEEP_EMPTY"
    while IFS= read -r -d '' d; do
        if [[ $d == "$src" ]]; then
            [[ $keep_src == 1 ]] && continue
            for name in "${keep_empty[@]}"; do [[ $(basename "$src") == "$(trim "$name")" ]] && continue 2; done
        fi
        [[ -d $d && ! -L $d && -z $(find "$d" -mindepth 1 -print -quit) ]] || continue
        echo "  removing empty folder ${d#"$ORG_ROOT"/}/"
        [[ -n ${DRY_RUN:-} ]] && continue
        rmdir -- "$d" || echo "  [FAIL] could not remove $d" >&2
    done < <(find "$src" -xdev -mindepth 1 \( "$@" \) -prune -o -type d -print0 | sort -rz
             printf '%s\0' "$src")
}

# Sets VAR to FILE's category by its extension, or by its contents for .ts/.raw; empty when
# none fits.
category_of() {
    local f=$2 name=${2##*/} ext=
    printf -v "$1" %s ""
    [[ $name == ?*.* ]] && ext=${name##*.} ext=${ext,,}
    [[ -n $ext ]] || return 0
    if [[ -n ${ext_cat[$ext]:-} ]]; then printf -v "$1" %s "${ext_cat[$ext]}"; return 0; fi
    # Extensions that also mean something else: moved only when the contents say so.
    case $ext in
        ts) if is_mpegts "$f"; then printf -v "$1" Videos; fi ;;
        raw) if [[ $(file -b --mime-type -- "$f" 2>/dev/null) == image/* ]]; then printf -v "$1" Pictures; fi ;;
    esac
    return 0
}

# True when subtitle FILE (Movie.srt, Movie.en.srt) sits next to a video it will move with.
has_video() {
    local s=$1 b v vcat
    b=${s%.*}
    for b in "$b" "${b%.*}"; do
        for v in "$b".*; do
            [[ -f $v && $v != "$s" ]] || continue
            category_of vcat "$v"
            [[ $vcat == Videos ]] && return 0
        done
    done
    return 1
}

# Adds FILE (found under SRC) to organize's list of files to move when its extension (or
# contents) belong to a category. A loose file in ORGANIZE_ROOT always moves: to Documents
# when no category fits (subtitles wait for their video). A file already in its category's
# folder (tidy) stays. Uses organize's locals.
pick_file() {
    local f=$1 src=$2 cat ext p
    for p in "${protected[@]}"; do [[ $f == "$p" ]] && return 0; done
    category_of cat "$f"
    [[ -n $cat && $src == "$root/$cat" ]] && return 0
    if [[ -z $cat && $src == "$root" ]]; then
        ext=${f##*.} ext=${ext,,}
        [[ " ${SUB_EXTS,,} " == *" $ext "* ]] && has_video "$f" && return 0
        cat=Documents
    fi
    [[ -n $cat ]] || return 0
    pick_f+=("$f") pick_src+=("$src") pick_cat+=("$cat")
}

# Moves FILE (found under SRC, keeping its path below SRC) into CAT's folder, or to the Trash
# when the same contents are already there, or only in the backup (checked on Drive first).
# Uses organize's locals and counters.
organize_file() {
    local f=$1 src=$2 cat=$3 rel dest dup where= h size mtime rc
    h=$(file_hash "$f") || { echo "  [FAIL] could not read $f" >&2; failed=$((failed + 1)); return 0; }
    dup=${BY_HASH[$cat $h]:-}
    if [[ -n $dup && ${BACKUP_ONLY[$dup]:-} == 1 ]]; then
        rc=0; in_backup "$dup" || rc=$?
        if ((rc == 1)); then
            echo "  (${dup#"$root"/} is no longer in the backup; dropping it from $INDEX_NAME)"
            BACKUP_ONLY[$dup]=0 BY_HASH[$cat $h]= dup=
        elif ((rc == 2)); then
            echo "  (can't reach the backup to check ${dup#"$root"/}; keeping ${f#"$root"/})"
            dup=
        fi
        where=", in the backup only"
    fi
    if [[ -n $dup ]]; then
        echo "  ${f#"$root"/} -> Trash (same as ${dup#"$root"/}$where)"
        [[ -n ${DRY_RUN:-} ]] && return 0
        if trash_file "$f"; then
            trashed=$((trashed + 1)) moved_out[$f]=1
        else
            echo "  [FAIL] could not move $f to the Trash" >&2; failed=$((failed + 1))
        fi
        return 0
    fi
    rel=${f#"$src"/}
    dest=$(unique_path "$root/$cat/$rel")
    echo "  ${f#"$root"/} -> ${dest#"$root"/}"
    read -r size mtime < <(stat -c '%s %Y' -- "$f")
    if [[ -n ${DRY_RUN:-} ]]; then
        idx_add "$dest" "$size" "$mtime" "$h"   # so later duplicates of it show up too
        moved_in[$dest]=1 moved_out[$f]=1
        [[ $cat == Videos ]] && move_subtitles "$f" "$dest"
        return 0
    fi
    if mkdir -p "$(dirname "$dest")" && mv -n -- "$f" "$dest" && [[ ! -e $f ]]; then
        moved=$((moved + 1)) moved_in[$dest]=1 moved_out[$f]=1
        idx_add "$dest" "$size" "$mtime" "$h"
        [[ $cat == Videos ]] && move_subtitles "$f" "$dest"
    else
        echo "  [FAIL] could not move $f" >&2; failed=$((failed + 1))
    fi
    return 0
}

# True when NAME looks like a copy: "x (1).jpg", "x - Copy.jpg", "x copy 2.jpg", "x.2.jpg",
# "x.jpg.1".
is_copy_name() {
    local stem=${1%.*}
    [[ $1 =~ \.[0-9]+$ || $stem =~ (\ \([0-9]+\)|[\ _-]+[Cc]opy([\ _-]*\(?[0-9]+\)?)?|\.[0-9]+)$ ]]
}

# True when duplicate A is the better one to keep than B: not named like a copy, then
# older, then in a shallower folder, then first by name.
keep_first() {
    local a=$1 b=$2 ca=0 cb=0 ma=${IDX_MTIME[$1]} mb=${IDX_MTIME[$2]} da db
    is_copy_name "${a##*/}" && ca=1
    is_copy_name "${b##*/}" && cb=1
    ((ca != cb)) && { ((ca < cb)); return; }
    ((ma != mb)) && { ((ma < mb)); return; }
    da=${a//[^\/]/} db=${b//[^\/]/}
    ((${#da} != ${#db})) && { ((${#da} < ${#db})); return; }
    [[ $a < $b ]]
}

# tidy: within category folder DIR, keeps one file of each set with the same contents and
# moves the others to the Trash. Only files tidy looks at (organize's PRUNE rules), not empty
# ones. Uses organize's locals and counters.
dedupe_folder() {
    local dir=$1 p h
    local -A best=()
    local -a files=()
    while IFS= read -r -d '' p; do
        [[ -z ${moved_out[$p]:-} && -n ${IDX_HASH[$p]:-} ]] && files+=("$p")
    done < <(find "$dir" -mindepth 1 -xdev \( "${prune[@]}" \) -prune -o -type f ! -empty -print0)
    # A dry run didn't really move anything in; find saw the real moves.
    if [[ -n ${DRY_RUN:-} ]]; then
        for p in "${!moved_in[@]}"; do
            [[ $p == "$dir"/* && -n ${IDX_HASH[$p]:-} && -z ${moved_out[$p]:-} ]] || continue
            ((${IDX_SIZE[$p]} > 0)) && files+=("$p")
        done
    fi
    for p in "${files[@]}"; do
        h=${IDX_HASH[$p]}
        if [[ -z ${best[$h]:-} ]] || keep_first "$p" "${best[$h]}"; then best[$h]=$p; fi
    done
    for p in "${files[@]}"; do
        h=${IDX_HASH[$p]}
        [[ $p != "${best[$h]}" ]] || continue
        echo "  ${p#"$root"/} -> Trash (same as ${best[$h]#"$root"/})"
        [[ -n ${DRY_RUN:-} ]] && continue
        if trash_file "$p"; then
            trashed=$((trashed + 1)) moved_out[$p]=1
        else
            echo "  [FAIL] could not move $p to the Trash" >&2; failed=$((failed + 1))
        fi
    done
    return 0
}

# Moves files by extension from the other folders in ORGANIZE_ROOT (or only from PATH) into
# its category folders, or to the Trash when the same contents are already in one of them.
# With --tidy (the tidy command), also goes through the four category folders themselves:
# files of another category move to that one's folder, and duplicates within each folder go
# to the Trash, keeping one (see keep_first).
organize() {
    local root cat e var src name f i only= tidy= d moved=0 trashed=0 failed=0
    root=$(abspath "$ORGANIZE_ROOT") ORG_ROOT=$root
    [[ ${1:-} == --tidy ]] && { tidy=1; shift; }
    if [[ -n ${1:-} ]]; then
        only=$(realpath -- "${1/#\~/$HOME}" 2>/dev/null) && [[ -d $only ]] || die "Not a folder: $1"
        for cat in "${CATEGORIES[@]}"; do
            [[ $only == "$root/$cat" || $only == "$root/$cat"/* ]] &&
                die "$only is in $root/$cat, where organize moves files to."
        done
        [[ -e $only/.git ]] && die "$only is a git repo; organize never touches those."
        [[ $only == "$root" ]] && only=
    fi
    lock
    # A scheduled catch-up run calls organize again in the same process: start from scratch.
    IDX_OLD=() IDX_SIZE=() IDX_MTIME=() IDX_HASH=() BY_HASH=() BACKUP_ONLY=()
    local -A ext_cat=()
    for cat in "${CATEGORIES[@]}"; do
        var=${cat^^}_EXTS
        for e in ${!var//,/ }; do ext_cat[${e,,}]=$cat; done
    done
    # The files this script needs to run, wherever they are, and a copy of it in ORGANIZE_ROOT
    # (the usual install location) when it runs from somewhere else.
    local protected=() p
    for p in "$SELF" "$ENV_FILE" "$RCLONE_CONFIG" "$KEY" "$root/${SELF##*/}"; do
        protected+=("$(realpath -m -- "$p")")
    done
    # Never take files out of (or look into) the backup folders, ORGANIZE_EXCLUDE or the targets.
    local keep=("${BK_SRC[@]}") skip=() excl=()
    IFS=, read -ra excl <<<"$ORGANIZE_EXCLUDE"
    for d in "${excl[@]}"; do d=$(trim "$d"); [[ -n $d ]] && keep+=("$(abspath "$d")"); done
    local prune=(-name '.*' -o -type d -exec test -e '{}/.git' ';')
    for cat in "${CATEGORIES[@]}"; do keep+=("$root/$cat"); done
    IFS=, read -ra skip <<<"$ORGANIZE_SKIP"
    for name in "${skip[@]}"; do
        name=$(trim "$name"); [[ -n $name ]] && prune+=(-o -type d -name "$name")
    done
    for d in "${keep[@]}"; do prune+=(-o -path "$d"); done

    echo "== $(date '+%F %T') ${tidy:+tidy + }organize ${only:-$root}${DRY_RUN:+ (dry run)}"
    # 1. The folders to go through: only PATH (even if it's excluded or backed up), or all of
    # ORGANIZE_ROOT's that aren't kept out.
    local srcs=()
    if [[ -n $only ]]; then
        srcs=("$only")
    else
        for src in "$root"/*/; do
            src=${src%/}
            [[ -L $src || -e $src/.git ]] && continue
            for name in "${skip[@]}"; do [[ $(trim "$name") == "${src##*/}" ]] && continue 2; done
            for d in "${keep[@]}"; do [[ $src == "$d" ]] && continue 2; done
            srcs+=("$src")
        done
    fi
    if [[ -n $tidy ]]; then
        for cat in "${CATEGORIES[@]}"; do [[ -d $root/$cat ]] && srcs+=("$root/$cat"); done
    fi
    # 2. The files to move.
    local pick_f=() pick_src=() pick_cat=()
    for src in "${srcs[@]}"; do
        while IFS= read -r -d '' f; do pick_file "$f" "$src"; done \
            < <(find "$src" -mindepth 1 -xdev \( "${prune[@]}" \) -prune -o -type f -mmin +10 -print0)
    done
    if [[ -z $only && $ORGANIZE_LOOSE == 1 ]]; then
        while IFS= read -r -d '' f; do pick_file "$f" "$root"; done \
            < <(find "$root" -mindepth 1 -maxdepth 1 -name '.*' -prune -o -type f -mmin +10 -print0)
    fi
    # 3. The checksums of what's already in the category folders (from directory.json when
    # unchanged), then move (or trash) the files and tidy up the emptied folders.
    for cat in "${CATEGORIES[@]}"; do
        [[ -d $root/$cat ]] || continue
        idx_load "$root/$cat"
        idx_scan "$root/$cat"
        idx_keep_backup_only "$root/$cat"
    done
    local -A moved_in=() moved_out=()
    for i in "${!pick_f[@]}"; do
        organize_file "${pick_f[i]}" "${pick_src[i]}" "${pick_cat[i]}"
    done
    if [[ -n $tidy ]]; then
        for cat in "${CATEGORIES[@]}"; do [[ -d $root/$cat ]] && dedupe_folder "$root/$cat"; done
    fi
    local keep_src
    for src in "${srcs[@]}"; do
        keep_src=0; [[ -n $only ]] && keep_src=1
        for cat in "${CATEGORIES[@]}"; do [[ $src == "$root/$cat" ]] && keep_src=1; done
        remove_empty_dirs "$src" "$keep_src" "${prune[@]}"
    done
    if [[ -z ${DRY_RUN:-} ]]; then
        for cat in "${CATEGORIES[@]}"; do
            [[ -d $root/$cat ]] || continue
            idx_write "$root/$cat"
        done
    fi
    echo "== organize: moved $moved, trashed $trashed duplicates, failed $failed"
    ((failed == 0))
}

# Lists the file extensions under DIR (default ORGANIZE_ROOT) that organize doesn't handle
# (none of the *_EXTS), with file count and total size: candidates to add to those lists.
# Sees what organize sees: hidden folders/files and ORGANIZE_SKIP are not entered, other
# filesystems are not crossed.
formats() {
    local root=${1:-$ORGANIZE_ROOT} cat var e name known= prune=(-name '.*') skip=()
    root=$(abspath "$root")
    [[ -d $root ]] || die "Not a folder: $root"
    for cat in "${CATEGORIES[@]}"; do
        var=${cat^^}_EXTS
        for e in ${!var//,/ }; do known+=" ${e,,}"; done
    done
    IFS=, read -ra skip <<<"$ORGANIZE_SKIP"
    for name in "${skip[@]}"; do
        name=$(trim "$name"); [[ -n $name ]] && prune+=(-o -type d -name "$name")
    done
    echo "File formats under $root that organize doesn't handle:"
    find "$root" -mindepth 1 -xdev \( "${prune[@]}" \) -prune -o -type f -printf '%s %f\n' |
        awk -v known="$known" '
            BEGIN { n = split(known, k, " "); for (i = 1; i <= n; i++) skip[k[i]] }
            {
                size = $1; name = substr($0, length($1) + 2)
                # "notes" or "Report v2.final draft" have no real extension.
                ext = "(none)"
                if (match(name, /\.[A-Za-z0-9]+$/) && RSTART > 1 && RLENGTH <= 11)
                    ext = tolower(substr(name, RSTART + 1))
                if (ext in skip) next
                count[ext]++; bytes[ext] += size
            }
            END { for (e in count) printf "%d\t%s\t%d\n", count[e], e, bytes[e] }' |
        sort -t$'\t' -k1,1nr -k2,2 |
        awk -F'\t' '
            function human(n,  u, i) {
                split("B KB MB GB TB", u, " ")
                for (i = 1; n >= 1024 && i < 5; i++) n /= 1024
                return sprintf(i == 1 ? "%d %s" : "%.1f %s", n, u[i])
            }
            BEGIN { printf "%8s  %-10s %10s\n", "FILES", "EXT", "SIZE" }
            { printf "%8d  %-10s %10s\n", $1, $2, human($3); files += $1; total += $3 }
            END { printf "%8d  %-10s %10s  (%d formats)\n", files, "total", human(total), NR }'
}

# Without arguments: puts each category folder's directory.json from the backup into
# ORGANIZE_ROOT/<Category>, creating the folder if needed, as a reference of what's backed up.
# An existing directory.json is never replaced.
restore_indexes() {
    local root cat dir name failed=()
    root=$(abspath "$ORGANIZE_ROOT")
    for cat in "${CATEGORIES[@]}"; do
        dir=$root/$cat
        name=$(backup_name "$dir") || { echo "skip $cat: $dir isn't in BACKUP_DIRS"; continue; }
        if [[ -e $dir/$INDEX_NAME ]]; then echo "skip $cat: $dir/$INDEX_NAME already exists"; continue; fi
        echo "current/$name/$INDEX_NAME -> $dir/$INDEX_NAME"
        [[ -n ${DRY_RUN:-} ]] && continue
        mkdir -p -- "$dir"
        rc copyto "gcrypt:current/$name/$INDEX_NAME" "$dir/$INDEX_NAME" || failed+=("$cat")
    done
    ((${#failed[@]} == 0)) || die "Failed: ${failed[*]}"
}

# Really removes PATH (in current/) from the backup: it moves to archive/<time>/, deleted
# after ARCHIVE_KEEP_DAYS like any old version, and leaves the category's directory.json.
forget() {
    need
    local path=${1:?usage: forget PATH, e.g. forget current/Pictures/old.jpg} rest root cat dir name sub p
    path=${path%/}
    [[ $path == current/?* ]] || die "forget only takes a path in current/, e.g. current/Pictures/old.jpg"
    lock
    rest=${path#current/}
    echo "== $(date '+%F %T') forget $path${DRY_RUN:+ (dry run)}"
    rc moveto "gcrypt:$path" "gcrypt:archive/$(date +%F_%H%M%S)/$rest" -v ${DRY_RUN:+--dry-run}
    [[ -z ${DRY_RUN:-} ]] || return 0
    root=$(abspath "$ORGANIZE_ROOT") ORG_ROOT=$root
    for cat in "${CATEGORIES[@]}"; do
        dir=$root/$cat
        name=$(backup_name "$dir") || continue
        [[ $rest == "$name" || $rest == "$name"/* ]] || continue
        sub=${rest#"$name"} sub=${sub#/}
        [[ -z $sub || ! -e $dir/$sub ]] ||
            echo "Note: $dir/$sub is still on this computer, so the next backup uploads it again."
        [[ -d $dir ]] || continue
        idx_load "$dir"; idx_scan "$dir"; idx_keep_backup_only "$dir"
        for p in "${!BACKUP_ONLY[@]}"; do
            [[ -z $sub || $p == "$dir/$sub" || $p == "$dir/$sub"/* ]] && BACKUP_ONLY[$p]=0
        done
        idx_write "$dir"
    done
}

restore() {
    need
    (($#)) || { restore_indexes; return; }
    local path=$1 dest=${2:?usage: restore PATH DEST, or restore with no arguments}
    rc copy "gcrypt:$path" "$dest" --links --stats 1m --stats-one-line -v ${DRY_RUN:+--dry-run}
}

# What the timer runs. systemd never starts a second copy while one is running, so a tick
# that falls inside a long backup is skipped by systemd; catch it up here as soon as we finish.
scheduled() {
    local started
    while :; do
        started=$(date +%F_%H)
        backup
        [[ $(date +%F_%H) != "$started" ]] || break
        echo "== $(date '+%F %T') a scheduled run came due during this one; starting it now"
    done
}

install_timer() {
    [[ -f ${BASH_SOURCE[0]:-} ]] || die "Save the script to a file first (curl -fsSLo backup.sh <URL>)."
    command -v systemctl >/dev/null || die "systemd not found."
    [[ -f $RCLONE_CONFIG ]] || echo "Note: no $RCLONE_CONFIG yet; backups fail until you run setup."
    local dir=${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user
    mkdir -p "$dir"
    cat >"$dir/$UNIT.service" <<EOF
# Written by backup.sh install; rerun it after changing BOOT_DELAY/SCHEDULE.
[Unit]
Description=Encrypted backup to Google Drive (backup.sh)

[Service]
Type=oneshot
Environment="BACKUP_ENV=$ENV_FILE"
ExecStart="$SELF" scheduled
Nice=10
IOSchedulingClass=idle
EOF
    cat >"$dir/$UNIT.timer" <<EOF
# Written by backup.sh install; rerun it after changing BOOT_DELAY/SCHEDULE.
[Unit]
Description=backup.sh at boot and on schedule

[Timer]
OnStartupSec=$BOOT_DELAY
OnCalendar=$SCHEDULE

[Install]
WantedBy=timers.target
EOF
    systemctl --user daemon-reload
    systemctl --user enable --now "$UNIT.timer"
    # Without lingering, user timers only run while you're logged in (and not at boot).
    if [[ $(loginctl show-user "$USER" -p Linger --value 2>/dev/null) != yes ]]; then
        loginctl enable-linger "$USER" 2>/dev/null \
            || echo "Could not enable lingering; run: sudo loginctl enable-linger $USER"
    fi
    echo "Installed $dir/$UNIT.{service,timer}: backup $BOOT_DELAY after boot and $SCHEDULE."
    echo "Logs: $LOG_DIR/   Status: $SELF status"
}

uninstall_timer() {
    local dir=${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user
    systemctl --user disable --now "$UNIT.timer" 2>/dev/null || true
    rm -f "$dir/$UNIT.service" "$dir/$UNIT.timer"
    systemctl --user daemon-reload
    echo "Removed the $UNIT timer (logs in $LOG_DIR are kept)."
}

status() {
    systemctl --user list-timers "$UNIT.timer" --no-pager || true
    systemctl --user status "$UNIT.service" --no-pager --lines=0 || true
    local log="$LOG_DIR/$(date +%F).log"
    [[ -f $log ]] && { echo; echo "--- $log"; tail -n 20 "$log"; }
    return 0
}

case ${1:-} in
    setup) setup ;;
    check) check ;;
    backup) start_log backup; backup ;;
    organize) shift; start_log organize "$@"; organize "$@" ;;
    tidy) start_log tidy; organize --tidy ;;
    sync) shift; start_log sync "$@"; sync_ "$@" ;;
    scheduled) start_log scheduled; scheduled ;;
    install) install_timer ;;
    uninstall) uninstall_timer ;;
    status) status ;;
    ls) need; rc lsf "gcrypt:${2:-}" ;;
    restore) shift; restore "$@" ;;
    forget) shift; start_log forget "$@"; forget "$@" ;;
    formats) shift; formats "$@" ;;
    *) usage; exit 2 ;;
esac
