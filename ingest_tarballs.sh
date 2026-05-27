#!/usr/bin/env bash
# ------------------------------------------------------------
# ingest‑tarballs.sh
#   - Lists .tar.zst objects in an S3 bucket (excluding “archive/”)
#   - Downloads each tarball + its .meta.txt file
#   - Verifies the tarball with `check_signature`
#   - On success, ingests the tarball into CVMFS
#   - Removes local copies after ingest
#   - Moves the processed objects to <bucket>/archive
#
# Requirements:
#   * aws CLI (v2) configured with access to the bucket
#   * `check_signature` executable in $PATH
#   * cvmfs_server command available (root / sudo rights)
#   * Destination directory must be writable
#
# Author: EduGenAI (2026‑05‑27)
# ------------------------------------------------------------

set -euo pipefail   # strict mode
IFS=$'\n\t'         # sane field splitting

# -------------------- Configuration -------------------------
BUCKET="surf_hpcv_casparl_software_test"
DOWNLOAD_DIR="/data/cvmfs_s0_storage/staged_tarballs"
REPO_NAME="software.caspar.nl"
ARCHIVE_PREFIX="archive"
BASEDIR="versions"
# This ingest script also takes care of creating the `.cvmfscatalog` files if you have a .cvmfsdirtab configured
INGEST_SCRIPT="filesystem-layer/scripts/ingest-tarball.sh"

# Ensure the download directory exists
mkdir -p "${DOWNLOAD_DIR}"

# -------------------- Step 1: Get the list ------------------
# Store the keys in a Bash array called `tar_keys`
mapfile -t tar_keys < <(
    aws s3api list-objects-v2 \
        --bucket "${BUCKET}" \
        --query 'Contents[?ends_with(Key, `.tar.zst`) && !contains(Key, `archive/`)].Key' \
        --output text
)

# If no keys were found, exit early
if [[ ${#tar_keys[@]} -eq 0 ]]; then
    echo "No tarballs found in bucket '${BUCKET}' (excluding archive/)."
    exit 0
fi

echo "Found ${#tar_keys[@]} tarball(s) to process."

# -------------------- Step 2: Loop & process ----------------
for key in "${tar_keys[@]}"; do
    # Extract the base filename (e.g. 17798741550.tar.zst)
    filename=$(basename "${key}")

    # Derive the meta‑file name (same basename with .meta.txt suffix)
    meta_file="${filename}.meta.txt"

    # Full local paths
    local_tar="${DOWNLOAD_DIR}/${filename}"
    local_meta="${DOWNLOAD_DIR}/${meta_file}"

    echo "=== Processing ${filename} ==="

    # ---- Download tarball ----
    echo "Downloading tarball..."
    aws s3 cp "s3://${BUCKET}/${key}" "${local_tar}" || {
        echo "ERROR: Failed to download ${key}" >&2
        continue
    }

    # ---- Download meta file (if it exists) ----
    # The meta file is expected to sit next to the tarball in S3
    echo "Downloading meta file..."
    if aws s3 cp "s3://${BUCKET}/${key}.meta.txt" "${local_meta}" 2>/dev/null; then
        echo "Meta file downloaded."
    else
        echo "WARNING: No meta file found for ${filename}. Continuing without it."
        # Remove the variable so we don't pass a non‑existent file later
        local_meta=""
    fi

    # ---- Verify signature ----
    echo "Running check_signature..."
    if check_signature "${local_tar}"; then
        echo "Signature OK."
    else
        echo "ERROR: Signature verification failed for ${filename}. Skipping ingest." >&2
        # Optionally clean up the bad files
        rm -f "${local_tar}" "${local_meta}"
        continue
    fi

    # ---- Ingest into CVMFS ----
    echo "Ingesting into CVMFS (${REPO_NAME})..."
    if $INGEST_SCRIPT "${REPO_NAME}" "${local_tar}"; then
        echo "Ingest succeeded for ${filename}."
    else
        echo "ERROR: cvmfs_server ingest failed for ${filename}." >&2
        # Keep the files for troubleshooting
        continue
    fi

    # ---- Clean up local copies ----
    echo "Removing local files..."
    rm -f "${local_tar}" "${local_meta}"

    # ---- Archive the objects in S3 ----
    # Destination key = archive/<original‑key>
    archive_key="${ARCHIVE_PREFIX}/${key}"
    echo "Archiving S3 object to s3://${BUCKET}/${archive_key} ..."
    if ! aws s3 mv "s3://${BUCKET}/${key}" "s3://${BUCKET}/${archive_key}"; then
        echo "ERROR: Failed to move tarball to archive." >&2
    else
        echo "Tarball archived."
    fi

    # Archive the metadata file (if it existed)
    if [[ -n "${meta_file}" && -n "${local_meta}" ]]; then
        archive_meta_key="${ARCHIVE_PREFIX}/${key}.meta.txt"
        echo "Archiving metadata to s3://${BUCKET}/${archive_meta_key} ..."
        if ! aws s3 mv "s3://${BUCKET}/${key}.meta.txt" "s3://${BUCKET}/${archive_meta_key}"; then
            echo "ERROR: Failed to move metadata to archive." >&2
        else
            echo "Metadata archived."
        fi
    fi

done

echo "All done."
