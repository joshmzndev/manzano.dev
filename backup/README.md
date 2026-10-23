# backup.sh

`backup.sh` is one self-contained script that does two jobs on a Linux computer:

1. **Backup.** It copies your important folders to Google Drive, encrypted, every hour.
   It keeps old versions of changed or deleted files for 90 days.
2. **Organize.** It tidies your home folder by moving music, pictures, videos and documents
   into `~/Music`, `~/Pictures`, `~/Videos` and `~/Documents`. Duplicates go to the Trash.

Everything is set in the `CONFIG` section at the top of the script. You can change any
setting without editing the script: put the same line in a `.env` file next to it.

---

## What the backup does

- **Which folders.** By default these: `~/Documents`, `~/Videos`, `~/Music`, `~/Pictures`
  and `~/Desktop` (setting `BACKUP_DIRS`). Each one becomes a folder under `current/` in
  the backup. A folder that doesn't exist is skipped.
- **Where it goes.** To the Google Drive of `noreply@tyas.tyc.edu.tw`, in the folder
  `encrypted-backup/`. This account is fixed in the script on purpose, so it can't be
  changed by a setting.
- **Encrypted.** File contents *and* file names are encrypted with
  [rclone crypt](https://rclone.org/crypt/) before they leave the computer. On Drive you only
  see scrambled names. Without your password and salt nobody can read it, and that
  includes you, so keep them safe (see [Setup](#setup)).
- **With history.** If a file is changed, its old version moves to `archive/<date_time>/`
  instead of disappearing. Archive folders older than 90 days are deleted for good (setting
  `ARCHIVE_KEEP_DAYS`, 0 = keep forever).
- **Music, Pictures, Videos and Documents are never deleted from.** A file you delete
  from one of these four folders on the computer **stays in the backup**. Its entry stays in
  that folder's `directory.json` too, marked `"local": false`. You can always restore it
  later, and organize still counts it as "already have it" (see below). Removing a file from
  the backup for real takes a separate command: `./backup.sh forget current/Pictures/old.jpg`.
  That moves it to `archive/`, so it's deleted after 90 days like any old version.
  To free space, `./backup.sh free` deletes the files in these four folders that are
  already in the backup with the same contents (checked on Drive first; it asks before
  deleting). `./backup.sh free ~/Videos/2023` does only that folder.
- **Other folders are mirrored.** For `~/Desktop` and any other folder you add, `current/`
  matches the folder exactly. A file deleted there moves to `archive/` and is deleted after
  90 days.
- **What's left out.** Things that can be rebuilt or downloaded again: `node_modules`,
  Python caches and virtualenvs, the `.git` folder of git repos (their files are still
  backed up; push to keep the history), half-finished downloads (`.part`, `.crdownload`),
  editor swap files, office lock files, and disk/VM images (`.iso`, `.img`, `.vdi`, …). A folder
  containing a file named `.nobackup` or `CACHEDIR.TAG` is skipped entirely. You can add your
  own rules with `BACKUP_FILTER`.
- **Safe with odd files.** Symlinks are saved and restored as symlinks. USB drives and
  network mounts inside a backed-up folder aren't followed. Google's daily upload limit
  stops the run cleanly instead of retrying forever.
- **When.** After `install`, a systemd timer runs it 2 minutes after boot and then every
  hour, even when you're not logged in. Only one run happens at a time. If a run is still
  going when the next one is due, the next one waits and starts right after.
- **Logs.** One file per day in `~/.rclone_backup/logs/`, kept for 30 days.

## What organize does

`./backup.sh organize` looks through the folders in your home folder (`~/Downloads`,
`~/Stuff`, …) and moves files into the four category folders based on their extension:

| Goes to       | For example                                              |
|---------------|----------------------------------------------------------|
| `~/Music`     | mp3, flac, wav, ogg, m4a, opus, …                        |
| `~/Pictures`  | jpg, png, gif, webp, heic, avif, camera RAW files, …     |
| `~/Videos`    | mp4, mkv, mov, avi, webm, …                              |
| `~/Documents` | pdf, docx, odt, xlsx, pptx, epub, …                      |

The full lists are `MUSIC_EXTS`, `PICTURES_EXTS`, `VIDEOS_EXTS` and `DOCUMENTS_EXTS` in
the script. Files with other extensions stay where they are. `./backup.sh formats` lists the
extensions found in your home folder that aren't in any of those lists, with how many files
and how much space each one takes, so you can decide what to add.

How it behaves:

- **Subfolders are kept.** `~/Downloads/trip/beach.jpg` becomes `~/Pictures/trip/beach.jpg`.
- **Nothing is overwritten.** If the name is already taken, it becomes `beach (1).jpg`. A
  name only used in the backup counts as taken too, so a new file never replaces a
  backed-up one.
- **Duplicates go to the Trash.** If a file already exists in the folder it's headed for,
  it goes to the Trash instead. Files are compared by contents, never by name, so
  `beach (1).jpg` and `beach.jpg` with the same contents are duplicates. The same happens
  if two of the files being moved are identical, or if the file exists only in the backup.
  In that last case organize first asks Drive whether the file is really there. If it
  isn't, the file is moved normally and its entry is dropped from the list. If Drive can't
  be reached, the file is kept. Nothing is deleted outright, so you can restore anything
  from the file manager's Trash. Each category is checked on its own: pictures are only
  compared with `~/Pictures`, documents only with `~/Documents`.
- **Loose files in `~`.** Every file lying directly in your home folder gets sorted too. If
  its type doesn't fit a category, it goes to `~/Documents`. Hidden files (`.bashrc`, …)
  are never touched, and neither are this script, its `.env`, `rclone.conf` or the
  service account key. Turn this off with `ORGANIZE_LOOSE=0`.
- **One folder only.** `./backup.sh organize ~/Downloads` goes through just that folder.
  It works even for a folder organize normally skips, like `~/Desktop`.
- **Left alone:**
  - the backed-up folders (including `~/Desktop`) and anything in `ORGANIZE_EXCLUDE`
  - hidden folders, git repositories, and folders named in `ORGANIZE_SKIP` (`snap`,
    `node_modules`, …)
  - files changed in the last 10 minutes, which may still be downloading
- **Tricky types are checked.** Subtitles (`Movie.srt`, `Movie.en.srt`) move together with
  their video. A `.ts` file is moved only if it really is a video, because it's often
  TypeScript code. A `.raw` file is moved only if it really is a photo.
- **Cleans up.** Folders that end up empty are removed. `~/Downloads` itself is kept
  (`ORGANIZE_KEEP_EMPTY`), and so is the folder you named in `organize PATH`.
- **Keeps an index in each folder.** Every category folder has a `directory.json` listing
  its files: name, type, size, date and a sha256 checksum of the contents. organize uses it
  to spot duplicates without reading every file again. Only new or changed files are read,
  so the first run takes a while on big folders and later runs are quick. It lists the
  files on this computer (`"local": true`) and the ones only in the backup
  (`"local": false`). It's backed up along with the folder, so on another computer
  `./backup.sh restore` (see [Getting files back](#getting-files-back)) gives you the list
  of everything you have without downloading it. If you delete it, it's rebuilt from the
  files on this computer, but entries for files only in the backup are lost. If a
  `directory.json` was not written by organize, it is never used or replaced.

### Tidying folders that are already mixed up

organize never touches what's already inside Music, Pictures, Videos and Documents.
`./backup.sh tidy` does everything organize does, and also goes through those four folders:

- **Files in the wrong folder move.** A PDF in `~/Pictures/trip/` goes to
  `~/Documents/trip/`, a song in `~/Videos` goes to `~/Music`, and so on. If that folder
  already has the same contents, the file goes to the Trash instead. Files of unknown types
  stay where they are.
- **Duplicates within a folder go to the Trash, one copy is kept.** The one kept is, in
  order: the one whose name doesn't look like a copy (`(1)`, `- Copy`, `copy 2`, `.1`, …),
  then the oldest, then the one in the least deep subfolder. Empty files are never compared.
- **The same things are left alone as with organize:** hidden folders, git repositories,
  `ORGANIZE_SKIP` and `ORGANIZE_EXCLUDE`.

`~/Documents` is included, so **don't keep projects there**. A website folder in Documents
would have its images moved to Pictures. Keep projects on `~/Desktop` or in a folder listed
in `ORGANIZE_EXCLUDE` (e.g. `ORGANIZE_EXCLUDE=~/Desktop,~/Documents/Projects`).

tidy only runs when you start it, never on the schedule. Run `DRY_RUN=1 ./backup.sh tidy`
first and read what it would do.

Try organize first with `DRY_RUN=1 ./backup.sh organize`. That prints what would move without
moving anything. To run organize automatically before every backup, set
`ORGANIZE_ON_BACKUP=1`.

---

## Setup

You need a Google Workspace account (`noreply@tyas.tyc.edu.tw`) and admin access to that
Workspace, once.

### 1. Google side (one time)

The script signs in as a *service account* that is allowed to act on behalf of
`noreply@tyas.tyc.edu.tw` ("domain-wide delegation"). The files then belong to that account
and use its storage.

1. In the [Google Cloud console](https://console.cloud.google.com/), create a project (or
   pick one) and **enable the Google Drive API** for it.
2. Under **IAM & Admin → Service accounts**, create a service account. Open it,
   go to **Keys → Add key → JSON**, and download the key file.
3. Note the service account's **Client ID** (a long number on its details page).
4. In the [Google Admin console](https://admin.google.com/), go to **Security → Access and
   data control → API controls → Domain-wide delegation → Add new**. Enter that Client ID
   with the scope `https://www.googleapis.com/auth/drive`.
5. Save the key on the computer as `~/.secret/service_account.json` and make it private:
   `chmod 600 ~/.secret/service_account.json`. To keep it elsewhere, set
   `GOOGLE_SERVICE_ACCOUNT_FILE`.

### 2. On the computer

```bash
cd ~ && curl -fsSLo backup.sh <URL> && chmod +x backup.sh
./backup.sh setup     # installs what is missing (asks first), asks for an encryption password
./backup.sh check     # confirms the key, the delegation and the Drive connection
./backup.sh backup    # first backup (can take long the first time)
./backup.sh install   # run it at boot and every hour from now on
```

`setup` writes `~/.secret/rclone.conf` with your encryption password and a random salt, and **prints
the salt once**. Store the password and the salt somewhere safe that isn't this computer
or Google, such as a password manager. A copy of `rclone.conf` also works. If you lose them,
the backup can never be decrypted.

`check` can also confirm the delegation directly with Google if the Python packages are
installed (`setup` offers to install them, or `pip install google-api-python-client
google-auth`). Without them it skips that step and only tests rclone.

---

## Everyday commands

| Command | What it does |
|---|---|
| `./backup.sh backup` | Back up now (organizes first if `ORGANIZE_ON_BACKUP=1`). |
| `./backup.sh organize [PATH]` | Sort files into Music/Pictures/Videos/Documents (only PATH if given). |
| `./backup.sh tidy` | organize, plus sort out and deduplicate what's already inside the four folders. |
| `./backup.sh formats [DIR]` | Show file types organize doesn't handle yet. |
| `./backup.sh status` | Is the timer running, and the end of today's log. |
| `./backup.sh ls current` | Browse the backup with real (decrypted) names. |
| `./backup.sh restore current/Documents ~/restored` | Copy something back from the backup. |
| `./backup.sh restore` | Create `~/Music`, `~/Pictures`, `~/Videos`, `~/Documents` if missing and put each one's `directory.json` from the backup inside. |
| `./backup.sh sync SRC [NAME]` | Back up one extra folder once, to `current/NAME`. |
| `./backup.sh forget current/PATH` | Really remove a file or folder from the backup (it's moved to `archive/` and deleted after 90 days). |
| `./backup.sh free [PATH] [--yes]` | Delete files in Music, Pictures, Videos, Documents (or only under PATH) that are already backed up with the same contents, to free space. Asks first unless `--yes`; they stay in the backup. |
| `./backup.sh uninstall` | Stop the hourly backups (logs are kept). |

Put `DRY_RUN=1` in front of `backup`, `organize`, `tidy`, `sync`, `restore`, `forget` or `free` to see what would
happen without changing anything.

### Getting files back

- **The current version:** `./backup.sh restore current/Pictures/trip ~/restored-trip`
- **An older version, or a deleted file:** find it with `./backup.sh ls archive`, then e.g.
  `./backup.sh restore archive/2026-10-20_140000/Documents ~/restored-old`
- **Something organize trashed:** open the Trash in your file manager and restore it.
- **Just the file lists, e.g. on a new computer:** `./backup.sh restore` with nothing after
  it. It creates the four category folders if they don't exist and puts each one's
  `directory.json` from the backup inside. A `directory.json` that's already there is never
  replaced. organize keeps every entry (files you don't have here are marked
  `"local": false`), so a download of something already in the backup goes to the Trash
  instead of being stored twice. Restore the file itself whenever you want it back.

---

## Troubleshooting

- **`unauthorized_client` from `check`.** The domain-wide delegation from step 1.4 is
  missing, has the wrong Client ID, or uses another scope. It must be exactly
  `https://www.googleapis.com/auth/drive`. New delegations can take a few minutes, and
  occasionally longer, to start working.
- **"signed in as … expected noreply@…".** The key belongs to a different setup; check
  that `GOOGLE_SERVICE_ACCOUNT_FILE` points to the right key.
- **`No service account key at …`.** The key isn't where the script looks. Move it to
  `~/.secret/service_account.json`, or set `GOOGLE_SERVICE_ACCOUNT_FILE` in `.env`.
- **"no gio or trash-put".** organize can't reach the Trash. Install `libglib2.0-bin` or
  `trash-cli`.
- **Backups don't run while logged out.** `install` turns on "lingering" for your user. If
  that failed, run `sudo loginctl enable-linger $USER`.
- **Something went wrong in a scheduled run.** Run `./backup.sh status`, or read today's
  file in `~/.rclone_backup/logs/`.

## Files

| File | What it is |
|---|---|
| `backup.sh` | The script. |
| `.env` | Your settings, overriding the defaults in the script. Optional. |
| `~/.secret/rclone.conf` | Written by `setup`: the Drive connection and the encryption password. **Keep a copy safe.** |
| `~/.secret/service_account.json` | The Google key. Private (`chmod 600`). |
| `~/.rclone_backup/` | Logs and the lock file. |
| `~/Music/directory.json` (etc.) | organize's list of the files in each category folder, with checksums. |
