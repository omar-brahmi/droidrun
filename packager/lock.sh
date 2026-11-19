#!/bin/bash
# lock.sh lock <file or folder> <out.lock> | lock.sh unlock <in.lock> <out folder>
#
# The repository is public, so its workflow artifacts can be downloaded by anyone. What carries the user's apps (the IPA with
# their libraries and compiled code, logs and screenshots of them) is uploaded locked: tar, then AES-256 (openssl, PBKDF2) with
# the ARTIFACT_KEY secret. Unlock on the PC with the same key (kept in .artifact-key, which git ignores):
#     ARTIFACT_KEY=$(cat .artifact-key) bash packager/lock.sh unlock DroidRun-ipa.lock out
set -e
: "${ARTIFACT_KEY:?ARTIFACT_KEY is not set: refusing to upload app content unlocked}"
case "$1" in
    lock)
        tar -C "$(dirname "$2")" -cf - "$(basename "$2")" |
            openssl enc -aes-256-cbc -pbkdf2 -iter 200000 -salt -pass env:ARTIFACT_KEY -out "$3"
        ;;
    unlock)
        mkdir -p "$3"
        openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 -pass env:ARTIFACT_KEY -in "$2" | tar -C "$3" -xf -
        ;;
    *) echo "lock.sh lock <path> <out.lock> | unlock <in.lock> <dir>" >&2; exit 1 ;;
esac
