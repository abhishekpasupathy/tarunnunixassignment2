# Network Transfer Integrity and Resume Manager

A Bash utility for transferring a local file to an authorized remote SSH destination using rsync, verifying the transferred file with SHA-256, retrying transient failures, and recording status and duration.

## Requirements

- Bash
- OpenSSH client (`ssh`)
- `rsync`
- `sha256sum`
- `timeout`

On macOS, install rsync if needed:

```bash
brew install rsync
```

## Setup

```bash
git clone https://github.com/abhishekpasupathy/tarunnunixassignment2.git
cd tarunnunixassignment2
chmod +x transfer_manager.sh
```

Make sure you have authorized SSH access to the remote machine. Add its host key to your `~/.ssh/known_hosts` by connecting interactively and verifying the fingerprint. Do not disable host-key checking.

The remote destination directory must already exist and be writable by the SSH user.

## Usage

```bash
./transfer_manager.sh SOURCE_FILE user@host:/absolute/remote/path [RETRIES] [TIMEOUT_SECONDS]
```

Example:

```bash
./transfer_manager.sh sample.txt student@192.168.1.20:/home/student/received 3 120
```

Arguments:
- `SOURCE_FILE`: local file to transfer
- `user@host:/absolute/remote/path`: authorized remote destination directory
- `RETRIES`: maximum attempts (default: 3)
- `TIMEOUT_SECONDS`: timeout for individual network operations (default: 120)

## Features

1. Validates source file, destination format, and remote directory access.
2. Uses `rsync --partial --append-verify` to preserve partial data and resume interrupted transfers.
3. Uses SSH with normal host-key verification; it never sets `StrictHostKeyChecking=no`.
4. Computes a local SHA-256 checksum and compares it with the remote checksum.
5. Retries failed transfers with a short increasing delay.
6. Records timestamps, attempt results, checksum verification, total duration, and final status in `logs/transfer.log`.
7. Preserves the original source file.

## Demonstration

Create a sample file:

```bash
printf 'Network transfer assignment test\n' > sample.txt
```

Run the script with a destination you are authorized to access:

```bash
./transfer_manager.sh sample.txt YOUR_USER@YOUR_HOST:/absolute/remote/directory
```

On the remote machine, verify the file:

```bash
sha256sum /absolute/remote/directory/sample.txt
```

View the log locally:

```bash
cat logs/transfer.log
```

## Notes

- This program transfers one file per invocation.
- It requires SSH key or other non-interactive authentication for reliable automated retries.
- Remote directory creation is intentionally not automatic: the script validates that the destination exists and is writable.
- Use only destinations and accounts for which you have authorization.