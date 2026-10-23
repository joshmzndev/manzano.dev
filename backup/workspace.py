"""Google Drive access as the TYAS bot account (noreply@tyas.tyc.edu.tw) only.

rclone does the backups (backup.sh). This checks that the service account's
domain-wide delegation lets it use Drive as noreply@, the same way rclone signs in.

    python workspace.py            # check the key and the Drive scope
"""

import os
import sys
from pathlib import Path

from google.oauth2 import service_account
from googleapiclient.discovery import build

HERE = Path(__file__).resolve().parent
KEY_FILE = Path(os.environ.get("GOOGLE_SERVICE_ACCOUNT_FILE", HERE / "service_account.json"))
# Fixed on purpose (no env override): nothing here acts as any other user.
BOT_EMAIL = "noreply@tyas.tyc.edu.tw"

# The scope rclone requests with `scope = drive`. It must be authorized for the service
# account's client ID in admin.google.com (Security > Access and data control > API
# controls > Domain-wide delegation), or every call fails with "unauthorized_client".
SCOPES = ["https://www.googleapis.com/auth/drive"]


def credentials():
    """Delegated credentials acting as noreply@."""
    if not KEY_FILE.exists():
        raise FileNotFoundError(
            f"Service account key not found at {KEY_FILE}. Set GOOGLE_SERVICE_ACCOUNT_FILE."
        )
    creds = service_account.Credentials.from_service_account_file(str(KEY_FILE), scopes=SCOPES)
    return creds.with_subject(BOT_EMAIL)


def drive():
    return build("drive", "v3", credentials=credentials(), cache_discovery=False)


def _gb(n):
    return f"{int(n) / 1e9:.1f} GB"


def check():
    """One cheap Drive call as noreply@; report who we are and the storage used."""
    print(f"Key file: {KEY_FILE}\nActing as: {BOT_EMAIL}\n")
    try:
        about = drive().about().get(fields="user(emailAddress),storageQuota").execute()
    except Exception as e:  # report, don't trace
        print(f"  [FAIL] drive: {str(e).splitlines()[0][:160]}")
        print("\nSee 'Troubleshooting' in README.md.")
        return False
    email = about["user"]["emailAddress"]
    if email.lower() != BOT_EMAIL:
        print(f"  [FAIL] drive: signed in as {email}, expected {BOT_EMAIL}")
        return False
    quota = about.get("storageQuota", {})
    limit = _gb(quota["limit"]) if "limit" in quota else "pooled / unlimited"
    print(f"  [ok]   drive: {email}, using {_gb(quota.get('usage', 0))} of {limit}")
    return True


if __name__ == "__main__":
    sys.exit(0 if check() else 1)
