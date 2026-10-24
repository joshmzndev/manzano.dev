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
GOOGLE_SERVICE_ACCOUNT_FILE=~/.config/service_account.json   # service account key (keep it chmod 600)
RCLONE_CONFIG=~/.config/rclone.conf   # written by setup; holds the encryption password + salt
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
# Before anything moves, every .zip organize looks at (also loose ones in ORGANIZE_ROOT when
# ORGANIZE_LOOSE=1, and zips inside zips) is unzipped next to itself and then deleted for good
# (not trashed), so its files get organized like any others: photos.zip -> photos/, or,
# when everything in it is in one folder, that folder (" (1)" when taken). Mac __MACOSX/
# junk is dropped. A zip that can't be fully extracted (damaged, password-protected) stays.
# Afterwards, empty folders in the organized folders are removed (checked empty first; a
# folder holding only hidden files isn't empty). The top-level folder itself goes too if it
# ends up empty, unless it's in ORGANIZE_KEEP_EMPTY or it's the PATH given to organize.
ORGANIZE_ROOT=~
ORGANIZE_ON_BACKUP=0          # 1 = run organize at the start of every backup
ORGANIZE_SKIP=snap,Templates,Public,bin,node_modules,venv,Git,git   # folder names never entered
ORGANIZE_EXCLUDE=~/Desktop    # folders (paths, comma-separated) never organized
ORGANIZE_KEEP_EMPTY=Downloads # top-level folders kept even when organize empties them
ORGANIZE_LOOSE=1              # 1 = also organize every loose file directly in ORGANIZE_ROOT
MUSIC_EXTS="mp3 flac wav ogg oga opus m4a aac wma aiff aif aifc ape wv dsf dff m4b mka amr tta
    mpc caf mid midi"
# Camera RAW: dng cr2 and the rest of the second line.
PICTURES_EXTS="jpg jpeg jpe png gif bmp webp tif tiff heic heif avif jxl psd xcf kra
    dng cr2 cr3 crw nef nrw arw srf sr2 orf rw2 raf pef srw 3fr fff iiq x3f rwl mrw erf mef mos kdc dcr"
VIDEOS_EXTS="mp4 m4v mkv mov avi wmv webm flv mpg mpeg 3gp 3g2 mts m2ts vob ogv divx rm rmvb asf mxf"
# conf svg, key (Keynote, but also TLS keys), archives, disk images, installers, scripts.
DOCUMENTS_EXTS="pdf doc docx odt rtf xls xlsx ods ppt pptx odp odg odf pages numbers djvu xps oxps
    epub mobi azw3 ics vcf pub md csv yaml eml backup age gpg txt log json conf"

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
# git internals: the files of a repo are backed up, its history can be cloned again
- .git/**
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
# organize temp files a run that was killed outright left behind (the next organize removes them)
- .unzip.??????/**
- .directory.json.??????*
- .organize.??????
'

die() { echo "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
Usage: backup.sh COMMAND

  setup              install missing prerequisites (asks first), write rclone.conf (asks
                     for the encryption password; a random salt is generated and printed
                     once), and a commented .env if there is none
  check              key + delegation (as noreply@), then the rclone remotes
  backup             sync every folder in BACKUP_DIRS (default: ~/Documents, ~/Videos,
                     ~/Music, ~/Pictures, ~/Desktop), then delete archive/ versions older
                     than ARCHIVE_KEEP_DAYS; runs organize first if ORGANIZE_ON_BACKUP=1
  organize [PATH]    move music/pictures/videos/documents from the other folders in ~
                     (e.g. ~/Downloads), or only from PATH, into ~/Music, ~/Pictures,
                     ~/Videos, ~/Documents; with ORGANIZE_LOOSE=1 (and no PATH), every
                     loose file in ~ too (Documents when no category fits). Zips are
                     unzipped in place first, and then deleted.
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
  free [PATH] [--yes]
                     delete files in ~/Music, ~/Pictures, ~/Videos, ~/Documents (or only
                     under PATH in one of them) that are already in the backup with the
                     same contents (checked on Drive), to free space; asks first. They stay
                     in the backup and in directory.json ("local": false). Folders left
                     empty by that are removed too
  start [PATH]       organize (only PATH, if given), then backup, then free without asking
                     (free --yes, on all four folders); stops before free if the backup fails
  install            systemd user timer: backup BOOT_DELAY after boot + every hour
  uninstall          remove that timer
  status             timer state + the end of today's log

Settings: CONFIG at the top of the script; override any of them in .env or the environment.
DRY_RUN=1: sync/backup/organize/tidy/restore/forget/free only show what they would do.
backup/organize/sync/forget/free log to STATE_DIR/logs/ (and the terminal, when there is one).
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
    # tee ignores the stop signals: Ctrl-C would kill it first, and the end of the run (with
    # the "stopped" line) would never reach the log.
    if [[ -t 1 ]]; then exec > >(trap '' INT TERM HUP; exec tee -a "$log") 2>&1; else exec >>"$log" 2>&1; fi
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

# The temp file/folder being worked on right now (unzip_file, idx_write, move_file, setup),
# removed if the run is stopped. Ctrl-C, systemd's stop and a closed terminal go through
# exit, so the EXIT trap runs for them too.
CLEAN_TMP=()
clean_tmp() { ((${#CLEAN_TMP[@]} == 0)) || rm -rf -- "${CLEAN_TMP[@]}"; }

# Between defer_stop and allow_stop (a few quick steps that must not be split up), a stop
# waits for allow_stop. Child processes still get the signal, so those steps check what
# really happened rather than trusting exit codes.
STOP_DEFERRED= STOP_PENDING=
on_stop() {
    if [[ -n $STOP_DEFERRED ]]; then STOP_PENDING="$1 $2"; return; fi
    echo "== $(date '+%F %T') stopped by $1; run the same command again to continue" || true
    exit "$2"
}
defer_stop() { STOP_DEFERRED=1; }
allow_stop() { STOP_DEFERRED=; [[ -z $STOP_PENDING ]] || on_stop $STOP_PENDING; }
trap clean_tmp EXIT
trap 'on_stop SIGINT 130' INT
trap 'on_stop SIGTERM 143' TERM
trap 'on_stop SIGHUP 129' HUP

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

# chmod 600 the key and rclone.conf, and 700 their folders (e.g. ~/.config). Folders that
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
#ORGANIZE_SKIP=snap,Templates,Public,bin,node_modules,venv,Git,git
#ORGANIZE_EXCLUDE=~/Desktop
#ORGANIZE_LOOSE=0
EOF
    )
    echo "Wrote $ENV_FILE (all defaults, commented out)."
}

# What setup installs when it's missing, one per line: "CHECK|apt-get|dnf|pacman|zypper"
# package. CHECK is a command (any of several, space-separated) or py:MODULE. rclone itself
# comes from rclone.org/install.sh (which needs curl + unzip), as distro ones can be < v1.53.
readonly PREREQS=(
    "curl|curl|curl|curl|curl"
    "unzip|unzip|unzip|unzip|unzip"
    "file|file|file|file|file"
    "gio trash-put|libglib2.0-bin|glib2|glib2|glib2-tools"
    "python3|python3|python3|python|python3"
    "py:google.oauth2.service_account|python3-google-auth|python3-google-auth|python-google-auth|python3-google-auth"
    "py:googleapiclient.discovery|python3-googleapi|python3-google-api-client|python-google-api-python-client|python3-google-api-python-client"
)

# Installs the missing PREREQS with the system package manager, after asking. Never fatal:
# without them only some steps fail or are skipped (see check, organize).
install_prereqs() {
    local pm= i=0 entry test ok py=${PYTHON:-python3}
    local -a cols missing=() pkgs=()
    for pm in apt-get dnf pacman zypper; do command -v "$pm" >/dev/null && break; pm=; done
    case $pm in apt-get) i=1 ;; dnf) i=2 ;; pacman) i=3 ;; zypper) i=4 ;; esac
    for entry in "${PREREQS[@]}"; do
        IFS='|' read -ra cols <<<"$entry"
        ok=
        for test in ${cols[0]}; do
            if [[ $test == py:* ]]; then "$py" -c "import ${test#py:}" 2>/dev/null && ok=1
            else command -v "$test" >/dev/null && ok=1; fi
        done
        [[ $ok ]] || { missing+=("${cols[0]}"); pkgs+=("${cols[i]}"); }
    done
    ((${#missing[@]})) || return 0
    if [[ -z $pm ]]; then
        echo "[WARN] missing, install them yourself: ${missing[*]}" >&2; return 0
    fi
    ask "Missing: ${missing[*]}. Install ${pkgs[*]} with $pm (sudo)?" || return 0
    case $pm in
        apt-get) sudo apt-get update && sudo apt-get install -y "${pkgs[@]}" ;;
        dnf) sudo dnf install -y "${pkgs[@]}" ;;
        pacman) sudo pacman -S --needed --noconfirm "${pkgs[@]}" ;;
        zypper) sudo zypper --non-interactive install "${pkgs[@]}" ;;
    esac || echo "[WARN] $pm couldn't install everything; setup continues." >&2
}

setup() {
    [[ -f $ENV_FILE ]] || write_env_template
    install_prereqs
    if ! command -v rclone >/dev/null; then
        ask "rclone is not installed. Install it now with rclone.org/install.sh (sudo)?" \
            || die "Install rclone (v1.53+): https://rclone.org/install/"
        curl -fsSL https://rclone.org/install.sh | sudo bash
    fi
    need
    make_private
    [[ -e $RCLONE_CONFIG ]] && die "$RCLONE_CONFIG already exists. It holds the encryption
password: only delete it to start a new, empty backup."
    local pw pw2 salt obscured obscured2 tmp
    read -rsp "Encryption password: " pw </dev/tty; echo
    read -rsp "Again: " pw2 </dev/tty; echo
    [[ -n $pw && $pw == "$pw2" ]] || die "Passwords are empty or don't match."
    salt=$(head -c 32 /dev/urandom | base64 | tr -d '\n')
    obscured=$(printf %s "$pw" | rclone obscure -)
    obscured2=$(printf %s "$salt" | rclone obscure -)
    # Written in full to a temp file (mode 600) and then renamed: a stopped setup leaves no
    # half-written rclone.conf that a rerun would refuse to replace.
    (umask 077; mkdir -p "$(dirname "$RCLONE_CONFIG")")
    tmp=$(mktemp "$RCLONE_CONFIG.XXXXXX")
    CLEAN_TMP=("$tmp")
    cat >"$tmp" <<EOF
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
password = $obscured
password2 = $obscured2
EOF
    mv -f -- "$tmp" "$RCLONE_CONFIG"
    CLEAN_TMP=()
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
    # No --fast-list: once current/NAME held a few thousand files in many folders, a copy
    # with it sat at "0 B / 0 B" listing Drive for minutes; folder by folder it's done in a few.
    rc "$mode" "$src" "gcrypt:current/$name" \
        "${filters[@]}" --filter-from - --ignore-case \
        --exclude-if-present .nobackup --exclude-if-present CACHEDIR.TAG \
        --one-file-system --links --skip-specials \
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

# Sets VAR to PATH, or "PATH (1).ext", "PATH (2).ext", ... whichever isn't taken yet, here or
# by a file that's only in the backup (which a new file there would replace), or by an
# earlier move in a dry run. A name without an extension gets " (1)" at the end. Sets a
# variable rather than printing, so no $(...) subshell can be killed halfway by a stop.
taken() { [[ -e $1 || ${BACKUP_ONLY[$1]:-} == 1 || -n ${moved_in[$1]:-} ]]; }
unique_path() {
    local p=$2 base=$2 ext= n=1
    if taken "$p"; then
        [[ ${p##*/} == ?*.* ]] && base=${p%.*} ext=.${p##*.}
        while taken "$base ($n)$ext"; do n=$((n + 1)); done
        p="$base ($n)$ext"
    fi
    printf -v "$1" %s "$p"
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
    CLEAN_TMP=("$tmp" "$tmp.files")
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
    CLEAN_TMP=()
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

# Moves FILE to DEST (a free name) like mv -n; true when FILE is gone. Across filesystems mv
# copies straight to DEST, and a stopped run would leave half a file there: the copy goes to
# a hidden temp file instead (in DEST's category folder, where organize looks for leftovers),
# which is renamed to DEST once it's complete.
move_file() {
    local f=$1 dest=$2 rel top tmp
    if [[ $(stat -c %d -- "$f") == "$(stat -c %d -- "${dest%/*}")" ]]; then
        mv -n -- "$f" "$dest" || true
        [[ ! -e $f ]]; return
    fi
    top=${dest%/*}
    if [[ $dest == "$ORG_ROOT"/*/* ]]; then rel=${dest#"$ORG_ROOT"/} top=$ORG_ROOT/${rel%%/*}; fi
    tmp=$(mktemp "$top/.organize.XXXXXX") || return 1
    CLEAN_TMP=("$tmp")
    if ! cp -p -- "$f" "$tmp"; then rm -f -- "$tmp"; CLEAN_TMP=(); return 1; fi
    # The copy is complete. Until the original is gone a stop waits, so the file never ends
    # up in both places.
    defer_stop
    mv -n -- "$tmp" "$dest" || true
    if [[ ! -e $tmp ]]; then
        CLEAN_TMP=()
        rm -f -- "$f" || true
        if [[ -e $f ]]; then rm -f -- "$dest"; fi   # the original can't be deleted: undo
    fi
    rm -f -- "$tmp"; CLEAN_TMP=()
    allow_stop
    [[ ! -e $f ]]
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
            unique_path to "${dest%.*}${s#"$base"}"
            echo "  ${s#"$ORG_ROOT"/} -> ${to#"$ORG_ROOT"/}"
            [[ -n ${DRY_RUN:-} ]] && continue
            move_file "$s" "$to" || echo "  [FAIL] could not move $s" >&2
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

# Unzips ZIP next to itself, then deletes it: into a folder named after it (photos.zip ->
# photos/), or, when everything in it is in one folder, that folder. The zip stays when it
# can't be fully extracted (damaged, password-protected: unzip gets an empty password rather
# than asking). Uses organize's locals and counters.
unzip_file() {
    local z=$1 dir=${1%/*} tmp to
    local -a entries=()
    if [[ -n ${DRY_RUN:-} ]]; then
        echo "  ${z#"$root"/} -> unzipped where it is, then deleted"
        return 0
    fi
    tmp=$(mktemp -d "$dir/.unzip.XXXXXX") || { echo "  [FAIL] could not unzip $z" >&2; failed=$((failed + 1)); return 0; }
    # Until the zip is deleted below, what's in tmp is only a copy: safe to remove if stopped.
    CLEAN_TMP=("$tmp")
    if ! unzip -qq -P '' -d "$tmp" "$z" </dev/null >/dev/null 2>&1; then
        echo "  [WARN] could not unzip ${z#"$root"/} (damaged or password-protected?), leaving it" >&2
        rm -rf -- "$tmp"; CLEAN_TMP=()
        return 0
    fi
    rm -rf -- "$tmp/__MACOSX"
    for to in "$tmp"/* "$tmp"/.[!.]* "$tmp"/..?*; do [[ -e $to || -L $to ]] && entries+=("$to"); done
    # From the move out of tmp until the zip is deleted, a stop waits: the files would be both
    # unzipped and still in the zip, and the next run would unzip them a second time.
    defer_stop
    if ((${#entries[@]} == 1)) && [[ -d ${entries[0]} && ! -L ${entries[0]} ]]; then
        unique_path to "$dir/${entries[0]##*/}"
        mv -n -- "${entries[0]}" "$to" || true
        rmdir -- "$tmp" 2>/dev/null || true   # only works when the move did
    elif ((${#entries[@]} == 0)); then
        to=; rmdir -- "$tmp" || true
    else
        unique_path to "${z%.*}"
        mv -n -- "$tmp" "$to" || true
    fi
    if [[ -e $tmp ]]; then
        echo "  [FAIL] could not move what $z holds out of $tmp" >&2; failed=$((failed + 1))
        allow_stop; return 0
    fi
    CLEAN_TMP=()
    echo "  ${z#"$root"/} -> ${to:+unzipped into ${to#"$root"/}/, }zip deleted"
    # Its files keep their dates from the zip: don't wait 10 minutes for recently zipped ones.
    if [[ -n $to ]]; then
        local pat=${to//\\/\\\\}; pat=${pat//\*/\\*}; pat=${pat//\?/\\?}; pat=${pat//\[/\\[}
        fresh+=(-o -path "$pat/*")
    fi
    if rm -f -- "$z" && [[ ! -e $z ]]; then
        unzipped=$((unzipped + 1))
    else
        echo "  [FAIL] could not delete $z" >&2; failed=$((failed + 1))
    fi
    allow_stop
}

# Unzips every .zip under SRC that organize looks at (same PRUNE rules, not changed in the
# last 10 minutes), zips found inside zips too; with --loose only the ones directly in SRC.
# Uses organize's locals and counters.
unzip_all() {
    local depth=() z p found
    [[ $1 == --loose ]] && { depth=(-maxdepth 1); shift; }
    while :; do
        found=0
        while IFS= read -r -d '' z; do
            [[ -z ${unzip_tried[$z]:-} ]] || continue
            unzip_tried[$z]=1 found=1
            for p in "${protected[@]}"; do [[ $z == "$p" ]] && continue 2; done
            unzip_file "$z"
        done < <(find "$1" -mindepth 1 "${depth[@]}" -xdev \( "${prune[@]}" \) -prune -o \
                     -type f -iname '*.zip' \( "${fresh[@]}" \) -print0)
        ((found)) || break
    done
}

# Adds FILE (found under SRC) to organize's list of files to move when its extension (or
# contents) belong to a category. A loose file in ORGANIZE_ROOT always moves: to Documents
# when no category fits (subtitles wait for their video). A file already in its category's
# folder (tidy) stays. Uses organize's locals.
pick_file() {
    local f=$1 src=$2 cat ext p
    for p in "${protected[@]}"; do [[ $f == "$p" ]] && return 0; done
    # A dry run didn't really unzip (and delete) it.
    [[ -n ${DRY_RUN:-} && -n ${unzip_tried[$f]:-} ]] && return 0
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
    unique_path dest "$root/$cat/$rel"
    echo "  ${f#"$root"/} -> ${dest#"$root"/}"
    read -r size mtime < <(stat -c '%s %Y' -- "$f")
    if [[ -n ${DRY_RUN:-} ]]; then
        idx_add "$dest" "$size" "$mtime" "$h"   # so later duplicates of it show up too
        moved_in[$dest]=1 moved_out[$f]=1
        [[ $cat == Videos ]] && move_subtitles "$f" "$dest"
        return 0
    fi
    mkdir -p "$(dirname "$dest")" || { echo "  [FAIL] could not move $f" >&2; failed=$((failed + 1)); return 0; }
    # Subtitles first: if the run stops in between, the video is still here and the next run
    # moves it to the same place, next to them (alone, subtitles would never move).
    [[ $cat == Videos ]] && move_subtitles "$f" "$dest"
    if move_file "$f" "$dest"; then
        moved=$((moved + 1)) moved_in[$dest]=1 moved_out[$f]=1
        idx_add "$dest" "$size" "$mtime" "$h"
    else
        echo "  [FAIL] could not move $f" >&2; failed=$((failed + 1))
        # Its subtitles went ahead: put them back next to it.
        [[ $cat == Videos ]] && move_subtitles "$dest" "$f"
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

# Removes what a run that was killed outright (no EXIT trap) left under DIR: .unzip.* folders
# (their zip is still there, so they're only a copy), move_file's .organize.* copies (the
# original is still there too) and directory.json temp files. Hidden,
# so organize never looks at them otherwise. Extra find args (e.g. -maxdepth 1) go first.
# Uses organize's locals (we hold the lock: no other run is using them).
clean_stale() {
    local dir=$1 p
    shift
    while IFS= read -r -d '' p; do
        echo "  removing ${p#"$root"/}, left by a run that was stopped"
        [[ -n ${DRY_RUN:-} ]] && continue
        rm -rf -- "$p" || echo "  [FAIL] could not remove $p" >&2
    done < <(find "$dir" -mindepth 1 "$@" -xdev \
                 \( -type d -name '.unzip.??????' -prune -print0 \) -o \
                 \( -type f \( -name ".$INDEX_NAME.??????" -o -name ".$INDEX_NAME.??????.files" \
                               -o -name '.organize.??????' \) -print0 \) -o \
                 \( "${prune[@]}" \) -prune)
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
    # 0. Loose zips first, so the folders they unzip into are gone through below.
    local -A unzip_tried=() moved_in=() moved_out=()
    local unzipped=0 has_unzip=1 fresh=(-mmin +10)
    command -v unzip >/dev/null || { has_unzip=; echo "  [WARN] no unzip: install it to have zips unzipped" >&2; }
    [[ -z $only && $ORGANIZE_LOOSE == 1 ]] && clean_stale "$root" -maxdepth 1
    for cat in "${CATEGORIES[@]}"; do [[ -d $root/$cat ]] && clean_stale "$root/$cat" -maxdepth 1; done
    [[ -n $has_unzip && -z $only && $ORGANIZE_LOOSE == 1 ]] && unzip_all --loose "$root"
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
    for src in "${srcs[@]}"; do clean_stale "$src"; done
    if [[ -n $has_unzip ]]; then
        for src in "${srcs[@]}"; do unzip_all "$src"; done
    fi
    # 2. The files to move.
    local pick_f=() pick_src=() pick_cat=()
    for src in "${srcs[@]}"; do
        while IFS= read -r -d '' f; do pick_file "$f" "$src"; done \
            < <(find "$src" -mindepth 1 -xdev \( "${prune[@]}" \) -prune -o -type f \( "${fresh[@]}" \) -print0)
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
        # Saved now as well, so the hashing isn't lost if the run is stopped before the end
        # (an entry is only reused while the file's size and time still match).
        [[ -z ${DRY_RUN:-} ]] && idx_ours "$root/$cat" && idx_write "$root/$cat"
    done
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
    echo "== organize: unzipped $unzipped, moved $moved, trashed $trashed duplicates, failed $failed"
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

# Deletes local files in the four category folders (or only under PATH in one of them)
# whose identical contents are already in current/ on Drive, checked by rclone cryptcheck
# (the checksum of each encrypted file there). Those folders are only added to, so the
# backup keeps the files, and directory.json keeps them as "local": false. Mirrored folders
# are refused: the next backup would move their deleted files to archive/, and
# prune_archive deletes them for good after ARCHIVE_KEEP_DAYS. Folders emptied by the
# deletions are removed, up to the category folder. Asks first, unless --yes.
free() {
    need
    local yes= arg only= root cat dir name sub src dst stamp match f p d size n=0 total=0 freed=0 failed=0
    local -a dirs=() opts=() files=()
    local -A emptied=()
    for arg in "$@"; do
        if [[ $arg == --yes || $arg == -y ]]; then yes=1
        elif [[ -z $only ]]; then
            only=$(realpath -e -- "${arg/#\~/$HOME}" 2>/dev/null) || die "Not found: $arg"
        else die "usage: free [PATH] [--yes]"
        fi
    done
    root=$(abspath "$ORGANIZE_ROOT") ORG_ROOT=$root
    for cat in "${CATEGORIES[@]}"; do
        dir=$root/$cat
        [[ -z $only || $only == "$dir" || $only == "$dir"/* ]] || continue
        if ! backup_name "$dir" >/dev/null; then
            [[ -z $only ]] || die "$dir isn't in BACKUP_DIRS, so nothing in it is backed up."
            continue
        fi
        [[ -d $dir ]] && dirs+=("$dir")
    done
    [[ -z $only || ${#dirs[@]} -gt 0 ]] ||
        die "free only works in $root/{$(IFS=,; echo "${CATEGORIES[*]}")}: other folders are mirrored, so a file deleted there is deleted from the backup too."
    [[ $only != */"$INDEX_NAME" ]] || die "$INDEX_NAME stays: it lists what's only in the backup."
    lock
    IDX_OLD=() IDX_SIZE=() IDX_MTIME=() IDX_HASH=() BY_HASH=() BACKUP_ONLY=()
    echo "== $(date '+%F %T') free ${only:-${dirs[*]}}${DRY_RUN:+ (dry run)}"
    # $stamp's time is when checking starts: a file modified after it may not be the version
    # in the backup.
    stamp=$(mktemp) match=$(mktemp)
    CLEAN_TMP=("$stamp" "$match")
    for dir in "${dirs[@]}"; do
        name=$(backup_name "$dir") sub=
        [[ -n $only && $only != "$dir" ]] && sub=${only#"$dir"/}
        src=$dir dst=gcrypt:current/$name
        if [[ -f $only ]]; then
            opts=(--files-from-raw -)   # just $sub, read from stdin
        else
            [[ -n $sub ]] && src=$dir/$sub dst=$dst/$sub
            # directory.json stays; hidden files aren't in it, and are left alone like organize does.
            opts=(--exclude "/$INDEX_NAME" --exclude '.*' --exclude '.*/**')
        fi
        echo "  checking $src against $dst"
        # A file that's missing or different there fails the check (and isn't in $match), so
        # rclone's exit code says nothing; make sure Drive is reachable instead.
        rc lsf --max-depth 1 "$dst" >/dev/null 2>&1 ||
            { echo "  [FAIL] can't read $dst" >&2; failed=$((failed + 1)); continue; }
        : >"$match"
        # Files changed in the last 10 minutes may still be changing (or not backed up yet).
        rc cryptcheck "$src" "$dst" --one-way --match "$match" --min-age 10m "${opts[@]}" \
            --one-file-system --skip-specials <<<"$sub" >/dev/null 2>&1 || true
        while IFS= read -r f; do
            p=$src/$f
            [[ -n $f && -f $p && ! -L $p ]] || continue
            echo "  backed up: ${p#"$root"/}"
            files+=("$p") n=$((n + 1)) total=$((total + $(stat -c %s -- "$p")))
        done <"$match"
    done
    echo "== $n file(s), $(numfmt --to=iec "$total")B, already in the backup"
    ((n)) && [[ -z ${DRY_RUN:-} ]] || return "$((failed > 0))"
    [[ -n $yes ]] || ask "Delete them from this computer for good (they stay in the backup)?" ||
        { echo "== nothing deleted"; return 0; }
    # Index everything first, so each deleted file keeps its entry, as "local": false.
    for dir in "${dirs[@]}"; do idx_load "$dir"; idx_scan "$dir"; idx_keep_backup_only "$dir"; done
    for p in "${files[@]}"; do
        if [[ $p -nt $stamp ]]; then echo "  [SKIP] ${p#"$root"/} changed meanwhile"; continue; fi
        size=$(stat -c %s -- "$p") || continue
        if rm -f -- "$p" && [[ ! -e $p ]]; then
            BACKUP_ONLY[$p]=1 freed=$((freed + size))
            # Its folders, up to (not including) the category folder, may be empty now.
            for dir in "${dirs[@]}"; do [[ $p == "$dir"/* ]] && break; done
            d=${p%/*}
            while [[ $d == "$dir"/* ]]; do emptied[$d]=1 d=${d%/*}; done
        else
            echo "  [FAIL] could not delete $p" >&2; failed=$((failed + 1))
        fi
    done
    # Deepest first, so a parent is emptied before it's checked. A folder with anything left
    # in it (hidden files count) stays.
    while IFS= read -r -d '' d; do
        [[ -d $d && ! -L $d && -z $(find "$d" -mindepth 1 -print -quit) ]] || continue
        echo "  removing empty folder ${d#"$root"/}/"
        rmdir -- "$d" || { echo "  [FAIL] could not remove $d" >&2; failed=$((failed + 1)); }
    done < <(((${#emptied[@]})) && printf '%s\0' "${!emptied[@]}" | sort -rz)
    for dir in "${dirs[@]}"; do idx_write "$dir"; done
    echo "== free: deleted $(numfmt --to=iec "$freed")B, failed $failed"
    ((failed == 0))
}

restore() {
    need
    (($#)) || { restore_indexes; return; }
    local path=$1 dest=${2:?usage: restore PATH DEST, or restore with no arguments}
    rc copy "gcrypt:$path" "$dest" --links --stats 1m --stats-one-line -v ${DRY_RUN:+--dry-run}
}

# organize (only PATH, if given), backup, free in one go, without asking: running start is
# the go-ahead for free. free always goes through all four folders, since PATH is usually
# somewhere organize moves files out of (e.g. ~/Downloads), not one of them.
# organize failures don't stop it (backup does the same with ORGANIZE_ON_BACKUP), but a
# failed backup does: backup dies before free runs.
start() {
    (($# <= 1)) || die "usage: start [PATH]"
    local failed=0
    organize "$@" || failed=1
    ORGANIZE_ON_BACKUP=0 backup
    free --yes
    ((failed == 0)) || die "organize had failures; see above."
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
    free) shift; start_log free "$@"; free "$@" ;;
    start) shift; start_log start "$@"; start "$@" ;;
    formats) shift; formats "$@" ;;
    *) usage; exit 2 ;;
esac
