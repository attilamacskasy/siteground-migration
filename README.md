# siteground-migration

Automation-first toolkit for moving a WordPress site off SiteGround onto your own Ubuntu box. Each script targets a discrete stage of the migration so you can run, verify, and recover safely.

## How the pieces fit together

1. **Prepare the new server** with `01_prepare_ubuntu.sh`, then double-check the result via `01_verify_ubuntu.sh`. If UFW rules come back wrong, run `01f_fix_firewall.sh` and verify again.
2. **Copy site contents** from SiteGround with `02_fetch_site.sh` (FTP/SFTP) or `03_ssh_backup_and_pull.sh` (SSH snapshot). Compare totals with `02_verify_transfer.sh` to spot gaps before cut-over.
3. **Tune the migrated WordPress** using `03_tune_and_finalize.sh` to import the database, swap credentials, strip SiteGround tooling, and optionally request Let’s Encrypt once DNS is in place.

Adjust the `EDIT ME` blocks at the top of each script before running them. They hold domain names, credentials, paths, and toggles that must match your environment. The scripts assume root (or sudo) access on the destination server.

## File-by-file

- `01_prepare_ubuntu.sh` provisions Apache, PHP-FPM 8.2, MariaDB, a self-signed cert, and a basic virtual host for the target domain. It also tunes PHP limits and opens firewall ports 80 and 443.
- `01_verify_ubuntu.sh` validates that the prepare step stuck: required packages, services, PHP overrides, virtual host wiring, HTTPS, and a live PHP execution test.
- `01f_fix_firewall.sh` cleans up UFW deny rules and re-applies the allow set so the verify script stops flagging port issues.
- `02_fetch_site.sh` pulls the WordPress files from SiteGround over FTP, FTPS, or SFTP using lftp, stores logs at `/root/02_fetch_site.log`, and preserves ownership for www-data.
- `02_verify_transfer.sh` compares remote versus local file counts and byte totals using lftp and local find to confirm the mirror succeeded.
- `03_gen_and_import_sg_key.sh` generates an ed25519 SSH key, shows the public key for SiteGround’s portal, adds a friendly alias to `~/.ssh/config`, and tests the connection.
- `03_ssh_backup_and_pull.sh` SSHes into SiteGround, toggles WordPress maintenance, tars up the install (skipping caches), downloads it, extracts to a staging directory, and fixes ownership.
- `03_tune_and_finalize.sh` installs WP-CLI if missing, creates the local database, imports the dump, updates `wp-config.php`, cleans SiteGround plugins, runs search-replace, flushes permalinks, and can optionally request Let’s Encrypt.
- `test/Screenshot 2025-11-04 005647.jpg` is a visual reminder of a successful lftp transfer check (used as a note-to-self, not part of the automation).
- `04_compare_local_trees.sh` compares two local copies (e.g., FTP vs SSH snapshot) and flags files missing on either side, byte deltas, or size mismatches.

## Prerequisites

- Fresh Ubuntu server with sudo access.
- DNS control for the domain so you can eventually point A/AAAA records at the new server or run Let’s Encrypt.
- Local machine with OpenSSH, lftp, and optional clipboard helpers (xclip, wl-copy, pbcopy) if you want automatic copy-paste support.

## Logging and reruns

- Long-running steps tee output into `/root/*.log` for later audits.
- Scripts are idempotent where possible: rerunning prepare/verify steps should succeed without manual cleanup.
- Keep credentials in a password manager; do not commit real passwords back into this repository.

## FTP vs SSH copies

- `02_fetch_site.sh` (FTP) mirrors the tree file-by-file and can take noticeably longer; in one run it left transient Let’s Encrypt challenges (`.well-known/acme-challenge/*`) in place until cleaned manually.
- `03_ssh_backup_and_pull.sh` (SSH) finishes faster thanks to tar+gzip, but will leave `.maintenance` behind if the script aborts before it disables maintenance mode.
- `04_compare_local_trees.sh` helps confirm both copies match; after deleting the stray `acme-challenge` files on the FTP tree and the `.maintenance` file on the SSH tree, the script reported identical file counts and byte totals.
- Expect the verification step to fail with a warning when artifacts differ; rerun after cleanup to ensure the transfer paths are truly aligned before cut-over.

## Next steps

Use the scripts in order, confirm each stage before moving on, then run a final manual smoke test of the site over HTTPS. Once DNS has propagated and Let’s Encrypt is active (if desired), schedule a follow-up to remove the self-signed cert artifacts.
