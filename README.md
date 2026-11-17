# Network Transfer Integrity and Resume Manager

A Bash utility for securely transferring one local file to an authorized SSH destination, resuming interrupted transfers with rsync, verifying SHA-256 integrity, retrying transient failures, and logging the result and elapsed time.

## Requirements

- Bash
- OpenSSH client (`ssh`)
- `rsync`
- A SHA-256 utility (`sha256sum` on Linux or `shasum` on macOS)
- `timeout` (Linux) or `gtimeout` (macOS)

### Install on macOS

```bash
brew install rsync coreutils
```

Homebrew installs GNU timeout as `gtimeout`; the script detects it automatically. macOS `shasum` is supported without extra installation.

## Clone and prepare

```bash
git clone https://github.com/abhishekpasupathy/tarunnunixassignment2.git
cd tarunnunixassignment2
chmod +x transfer_manager.sh
```

Configure SSH access to a machine and directory you are authorized to use. Verify the server's host-key fingerprint and retain normal SSH host-key checking. The script uses non-interactive SSH (`BatchMode=yes`) so authentication should be configured before running it, typically with an SSH key.

The remote destination directory must already exist and be writable by the SSH user.

## Run

```bash
./transfer_manager.sh SOURCE_FILE user@host:/absolute/remote/directory [RETRIES] [TIMEOUT_SECONDS]
```

Example (replace all placeholders with your own authorized server details):

```bash
./transfer_manager.sh sample.txt student@192.168.1.20:/home/student/received 3 120
```

Defaults are 3 attempts and 120 seconds per network operation.

## Demonstrate

```bash
printf 'Network transfer assignment test\n' > sample.txt
./transfer_manager.sh sample.txt YOUR_USER@YOUR_HOST:/absolute/remote/directory
cat logs/transfer.log
```

On the remote machine, independently verify the file:

```bash
sha256sum /absolute/remote/directory/sample.txt
```

On macOS remote hosts, use `shasum -a 256` if `sha256sum` is unavailable.

## Implemented features

1. Validates the source file, destination syntax, and remote directory write access.
2. Uses `rsync -a --partial --append-verify` to retain partial data and resume interrupted transfers while verifying appended data.
3. Uses SSH with host-key checking enabled; it never disables host-key verification.
4. Computes source and destination SHA-256 checksums and reports success only when they match.
5. Retries failed transfers/checksum checks with increasing short delays.
6. Applies a timeout to SSH and rsync network operations.
7. Logs timestamps, attempts, checksum results, final status, and total duration to `logs/transfer.log`.
8. Preserves the original source file.
9. Handles INT/TERM signals and logs interruption; rsync partial data is retained where supported.

## Notes and limitations

- One file is transferred per invocation.
- The remote directory is validated, not automatically created.
- For safe and predictable remote checksum commands, source filenames and remote paths are restricted to letters, digits, dot, underscore, slash and hyphen.
- A real remote SSH host is required for a live transfer test. The script cannot prove remote connectivity until run with valid host, credentials, and destination details.
- Use only systems and destinations for which you have explicit authorization.