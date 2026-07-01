#!/bin/bash

set -euo pipefail               # strict mode
IFS=$'\n\t'                     # sane field splitting

# ------------------------------------------------------------------
# Default configuration (overridable via command‑line options)
# ------------------------------------------------------------------
DEFAULT_BUCKET="surf_hpcv_casparl_software_test"
DEFAULT_DOWNLOAD_DIR="/data/cvmfs_s0_storage/staged_tarballs"
DEFAULT_REPO_NAME="software.caspar.nl"
DEFAULT_ARCHIVE_PREFIX="archive"
DEFAULT_BASEDIR="versions"
DEFAULT_INGEST_SCRIPT="filesystem-layer/scripts/ingest-tarball.sh"
DEFAULT_ALLOWED_SIGNERS="allowed_signers"

# ------------------------------------------------------------------
# Help text
# ------------------------------------------------------------------
print_help() {
    cat <<EOF
Usage: ${0##*/} [OPTIONS]

Options:
  -b, --bucket          S3 bucket name (default: $DEFAULT_BUCKET)
  -d, --download-dir    Local directory for downloads
                        (default: $DEFAULT_DOWNLOAD_DIR)
  -r, --repo-name       CVMFS repository name (default: $DEFAULT_REPO_NAME)
  -a, --archive-prefix  Prefix used when archiving objects in S3
                        (default: $DEFAULT_ARCHIVE_PREFIX)
  -B, --basedir         Base directory inside the repo (default: $DEFAULT_BASEDIR)
  -i, --ingest-script   Path to the ingest script (default:
                        $DEFAULT_INGEST_SCRIPT)
  -s, --signers-file    Path to the file with allowed signers (default:
                        $DEFAULT_ALLOWED_SIGNERS)
  --dry-run             Show what would be done without executing actions.
  --stage-only          Only download tarballs and meta files; skip ingest,
                        cleanup and archiving.
  -h, --help            Show this help message and exit.

All options are optional; omitted options fall back to the defaults shown above.
EOF
}

# ------------------------------------------------------------------
# Argument parsing (POSIX‑compatible)
# ------------------------------------------------------------------
BUCKET="$DEFAULT_BUCKET"
DOWNLOAD_DIR="$DEFAULT_DOWNLOAD_DIR"
REPO_NAME="$DEFAULT_REPO_NAME"
ARCHIVE_PREFIX="$DEFAULT_ARCHIVE_PREFIX"
BASEDIR="$DEFAULT_BASEDIR"
INGEST_SCRIPT="$DEFAULT_INGEST_SCRIPT"
ALLOWED_SIGNERS="$DEFAULT_ALLOWED_SIGNERS"

DRY_RUN=false
STAGE_ONLY=false
SIG_ONLY=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        -b|--bucket)          BUCKET="$2"; shift 2 ;;
        -d|--download-dir)    DOWNLOAD_DIR="$2"; shift 2 ;;
        -r|--repo-name)       REPO_NAME="$2"; shift 2 ;;
        -a|--archive-prefix)  ARCHIVE_PREFIX="$2"; shift 2 ;;
        -B|--basedir)         BASEDIR="$2"; shift 2 ;;
        -i|--ingest-script)   INGEST_SCRIPT="$2"; shift 2 ;;
        -s|--signers-file)    ALLOWED_SIGNERS="$2"; shift 2 ;;
        --dry-run)            DRY_RUN=true; shift ;;
        --stage-only)         STAGE_ONLY=true; shift ;;
        --signature-check-only) SIG_ONLY=true; shift ;;
        -h|--help)            print_help; exit 0 ;;
        *) echo "Unknown option: $1" >&2; print_help; exit 1 ;;
    esac
done

# ------------------------------------------------------------------
# Helper that either echoes or runs a command
# ------------------------------------------------------------------
run_cmd() {
    if $DRY_RUN; then
        # Show the exact command that would be executed
        echo "DRY‑RUN:" "$@"
    else
        # Execute the command with its arguments unchanged
        "$@"
    fi
}

# ------------------------------------------------------------------
# Ensure the download directory exists
# ------------------------------------------------------------------
run_cmd mkdir -p "${DOWNLOAD_DIR}"

# ------------------------------------------------------------------
# Step 1 – obtain the list of tarballs from S3
# ------------------------------------------------------------------
mapfile -t tar_keys < <(
    aws s3api list-objects-v2 \
        --bucket "${BUCKET}" \
        --query 'Contents[?ends_with(Key, `.tar.zst`) && !contains(Key, `archive/`)].Key' \
        --output text | tr '\t' '\n'
)

if [[ ${#tar_keys[@]} -eq 0 ]]; then
    echo "No tarballs found in bucket '${BUCKET}' (excluding archive/)."
    exit 0
fi

echo "Found ${#tar_keys[@]} tarball(s) to process."

# ------------------------------------------------------------------
# Step 2 – process each tarball
# ------------------------------------------------------------------
for key in "${tar_keys[@]}"; do
    filename=$(basename "${key}")
    meta_file="${filename}.meta.txt"
    sig_file="${filename}.sig"
    meta_sig_file="${meta_file}.sig"

    local_tar="${DOWNLOAD_DIR}/${filename}"
    local_tar_sig="${DOWNLOAD_DIR}/${sig_file}"
    local_meta="${DOWNLOAD_DIR}/${meta_file}"
    local_meta_sig="${DOWNLOAD_DIR}/${meta_sig_file}"

    meta_key=${key}.meta.txt
    sig_key=${key}.sig
    meta_sig_key=${key}.meta.txt.sig

    echo "=== Processing ${filename} ==="

    # ---- Download tarball ----
    echo "Downloading tarball... s3://${BUCKET}/${key} to ${local_tar}"
    run_cmd aws s3 cp "s3://${BUCKET}/${key}" "${local_tar}" || {
        echo "ERROR: Failed to download ${key}" >&2
        continue
    }

    # ---- Download metadata file (if it exists) ----
    echo "Downloading metadata file... s3://${BUCKET}/${meta_key} to ${local_meta}"
    run_cmd aws s3 cp "s3://${BUCKET}/${meta_key}" "${local_meta}" 2>/dev/null
    if [ $? -eq 0 ]; then
        echo "Metadata file downloaded."
    else
        echo "WARNING: No metadata file found for ${filename}. Continuing to next tarball (not ingesting ${filename})."
        continue
    fi

    # ---- Download tarball signature file ----
    echo "Downloading tarball signature file... s3://${BUCKET}/${sig_key} to ${local_tar_sig}"
    run_cmd aws s3 cp "s3://${BUCKET}/${sig_key}" "${local_tar_sig}"
    if [ $? -eq 0 ]; then
        echo "Tarball signature file downloaded."
    else
        echo "WARNING: Failed to download tarball signature file. Continuing to next tarball (not ingesting ${filename})."
        # No point in continuing this loop iteration, we'll fail the signature verification check anyway
        continue
    fi

    # ---- Download metadata signature file ----
    echo "Downloading metadata signature file... s3://${BUCKET}/${meta_sig_key} to ${local_meta_sig}"
    run_cmd aws s3 cp "s3://${BUCKET}/${meta_sig_key}" "${local_meta_sig}"
    if [ $? -eq 0 ]; then
        echo "Metadata signature file downloaded."
    else
        echo "WARNING. Failed to download metadata signature file. Continuing to next tarball (not ingesting ${filename})."
        continue
    fi

    # If stage‑only mode is active, skip everything after the download step
    if $STAGE_ONLY; then
        echo "Stage‑only mode: skipping signature check, ingest, cleanup and archiving for ${filename}."
        continue
    fi

    # ---- Verify signature ----
    echo "Running check_signature..."
    run_cmd eessi-bot-software-layer/scripts/sign_verify_file_ssh.sh --verify --allowed-signers-file "$ALLOWED_SIGNERS" --file "$local_tar"
    if [ $? -eq 0 ]; then
        echo "Signature OK."
    else
        echo "ERROR: Signature verification failed for ${filename}. Skipping ingest." >&2
        run_cmd rm -f "${local_tar}" "${local_meta}" "${local_tar_sig}" "${local_meta_sig}"
        continue
    fi

    # if signature-check-only is active, skip everything after the signature check
    if $SIG_ONLY; then
        echo "Signature-check-only mode: skipping archiving for ${filename}."
        run_cmd rm -f "${local_tar}" "${local_meta}" "${local_tar_sig}" "${local_meta_sig}"
        continue
    fi

    # ---- Ingest into CVMFS ----
    echo "Ingesting into CVMFS (${REPO_NAME}) using ${INGEST_SCRIPT}..."
    run_cmd "$INGEST_SCRIPT" "${REPO_NAME}" "${local_tar}"
    if [ $? -eq 0 ]; then
        echo "Ingest succeeded for ${filename}."
    else
        echo "ERROR: cvmfs_server ingest failed for ${filename}." >&2
        continue
    fi

    # ---- Clean up local copies ----
    echo "Removing local files..."
    run_cmd rm -f "${local_tar}" "${local_meta}" "${local_tar_sig}" "${local_meta_sig}"

    # ---- Archive the objects in S3 ----
    archive_key="${ARCHIVE_PREFIX}/${key}"
    echo "Archiving S3 ${key} to s3://${BUCKET}/${archive_key} ..."
    run_cmd aws s3 mv "s3://${BUCKET}/${key}" "s3://${BUCKET}/${archive_key}"
    if [ $? -eq 0 ]; then
        echo "Tarball archived."
    else
        echo "ERROR: Failed to move tarball to archive." >&2
    fi

    # Archive the metadata file
    archive_meta_key="${ARCHIVE_PREFIX}/${key}.meta.txt"
    echo "Archiving metadata ${meta_key} to s3://${BUCKET}/${archive_meta_key} ..."
    run_cmd aws s3 mv "s3://${BUCKET}/${meta_key}" "s3://${BUCKET}/${archive_meta_key}"
    if [ $? -eq 0 ]; then
        echo "Metadata archived."
    else
        echo "ERROR: Failed to move metadata to archive." >&2
    fi

    # Archive the signature file
    archive_sig_key="${ARCHIVE_PREFIX}/${key}.sig"
    echo "Archiving signature file ${sig_key} to s3://${BUCKET}/${archive_sig_key}"
    run_cmd aws s3 mv "s3://${BUCKET}/${sig_key}" "s3://${BUCKET}/${archive_sig_key}"
    if [ $? -eq 0 ]; then
        echo "Tarball signature file archived."
    else
        echo "ERROR: Failed to move tarball signature file to archive." >&2
    fi

    # Archive the metadata signature file
    archive_meta_sig_key="${ARCHIVE_PREFIX}/${key}.meta.txt.sig"
    echo "Archiving metadata signature file ${meta_sig_key} to s3://${BUCKET}/${archive_meta_sig_key}"
    run_cmd aws s3 mv "s3://${BUCKET}/${meta_sig_key}" "s3://${BUCKET}/${archive_meta_sig_key}"
    if [ $? -eq 0 ]; then
        echo "Metadata signature file archived."
    else
        echo "ERROR: Failed to move metadata signature file to archive." >&2
    fi

done

echo "All done."
