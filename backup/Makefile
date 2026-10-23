# Encrypted rclone backups to noreply@tyas.tyc.edu.tw's Google Drive (see README.md).
#
#   make setup                         write rclone.conf (asks for the encryption password)
#   make check                         key, delegation and rclone remotes
#   make sync SRC=/path [NAME=x]       mirror SRC to current/NAME; old versions go to archive/
#   make ls [P=current]                list the backup (decrypted names)
#   make restore P=current/x DEST=/path
#
# Add DRY=1 to sync/restore to see what they would do. KEY=/path/to/key.json overrides the key.

KEY ?= $(or $(GOOGLE_SERVICE_ACCOUNT_FILE),service_account.json)
export GOOGLE_SERVICE_ACCOUNT_FILE := $(abspath $(KEY))
export DRY_RUN := $(if $(filter 1,$(DRY)),1,)
RUN := $(CURDIR)/backup.sh

.PHONY: help setup check sync ls restore

help:
	@sed -n '3,9p' $(firstword $(MAKEFILE_LIST)) | sed 's/^# \{0,1\}//'

setup check:
	@$(RUN) $@

sync:
	@test -n "$(SRC)" || { echo "usage: make sync SRC=/path [NAME=x] [DRY=1]"; exit 1; }
	@$(RUN) sync "$(SRC)" $(NAME)

ls:
	@$(RUN) ls "$(P)"

restore:
	@test -n "$(P)" -a -n "$(DEST)" || { echo "usage: make restore P=current/x DEST=/path [DRY=1]"; exit 1; }
	@$(RUN) restore "$(P)" "$(DEST)"
