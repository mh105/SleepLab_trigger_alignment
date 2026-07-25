# EDF Deidentifier

EDF Deidentifier is a local PySide6 desktop application for one narrow
pseudonymization workflow. It scans only the top level of a folder selected by
the user, lets the user enter a study ID for each selected EDF, and then
deidentifies and renames those files in place.

This is not a general PHI scanner and has not been certified as satisfying
HIPAA Safe Harbor or any other deidentification standard. Use it only for the
clinical export format and privacy scope described below.

## Exact mutation and privacy scope

For each checked row, the application:

1. Reads the system auto-ID as the third whitespace-separated token in the
   EDF `local_rec_id` field.
2. Replaces the fixed 80-byte EDF patient-identification field with:

   ```text
   <auto-ID> X 01-JAN-1999 <study-ID>
   ```

3. Renames the file exactly to `<study-ID>.edf`.

Study IDs must be 1–40 ASCII letters, digits, underscores, or hyphens. Their
capitalization is preserved. The replacement must fit the EDF field.

The application deliberately does **not** alter `local_rec_id`, recording
start date or time, annotations, signal samples, or any other EDF header
field. It does not inspect annotation text for PHI. The team using it is
responsible for confirming that those preserved locations contain no PHI.
The table shows the PHI-bearing original filename, but does not display
patient-header contents.

The application does not save the original-filename-to-study-ID mapping,
recent-file history, CSV exports, or persistent logs. It does not send EDF
content to a network service. Original filenames and paths can still appear
temporarily on screen in the table and result dialog.

## Safety behavior

- Only `.edf` files directly inside the selected folder are considered.
  Subfolders are never scanned.
- All valid rows start checked. Files with malformed or unsupported fixed EDF
  headers remain visible but cannot be selected for processing.
- Before any file changes, the whole selected batch is validated. Missing or
  invalid study IDs, duplicate output names, an existing conflicting output
  file, malformed auto-IDs, and inadequate temporary-copy space block the
  batch.
- A final dialog warns that the patient IDs and original filenames will not
  be recoverable and requires explicit confirmation.
- Each EDF is streamed to a temporary file beside the original. The
  application changes only the patient-identification bytes, flushes the
  temporary file, reads it back, confirms its size, and verifies with SHA-256
  that every byte outside that field matches the source before committing it.
- The original file's permissions and modification time are preserved.
  Creation and access times are not guaranteed across Windows and macOS.
- During commit, the verified output is installed with an exclusive
  no-overwrite rename. The original is then moved to a random recovery name,
  verified again, and removed only after the installed output is verified and
  the directory is synchronized. On success, no backup or temporary file is
  retained.
- Files are processed sequentially. If an unexpected error occurs, completed
  files remain deidentified, the current file is left unchanged when its
  replacement has not been committed, and remaining files are untouched. If a
  failure occurs during commit, a deidentified output and/or a generic
  `.edf-deidentifier-rename-*.tmp` recovery file may remain rather than risk
  deleting data; the result dialog reports the exact state. A later batch is
  blocked until any such recovery file is resolved.
- `Stop` cancels an in-progress temporary copy safely or, if commit has
  already begun, stops before the next file.
- The result dialog reports each file as completed, failed, or untouched,
  together with the failed stage, error message, and temporary-file cleanup
  outcome. It does not report the OS, application version, or free-space
  details and does not save a report.

The safe-copy method temporarily needs approximately the size of the largest
selected EDF as free space in that folder. It is intended for ordinary local
folders and for external drives whose filesystem supports exclusive rename
operations. Atomic replacement is not guaranteed by all external filesystems,
network shares, or mapped hospital drives; on an unsupported filesystem the
application fails before removing the source and reports the error.

The commit protocol assumes that no other process changes directory entries
while a file is being committed. Do not run two deidentification batches
against the same folder, and close other software using the EDFs. For a locally
synchronized folder, pause synchronization for the batch and resume it only
after the result dialog appears. This is necessary because Windows and macOS
do not provide one portable operation that can atomically compare and delete a
directory entry across all supported filesystems.

Because processing is intentionally destructive and does not create backups,
use only an authorized source folder. Retain an independent source copy first
if required by institutional policy. Close programs that may have an EDF open
before processing it.

## Run from source

Python 3.11–3.14 is supported. On macOS, from this directory:

```bash
python3 -m venv .venv
source .venv/bin/activate
python -m pip install --upgrade pip
python -m pip install -e ".[test]"
python -m edf_deidentifier
```

On Windows PowerShell:

```powershell
py -3.12 -m venv .venv
.\.venv\Scripts\Activate.ps1
python -m pip install --upgrade pip
python -m pip install -e ".[test]"
python -m edf_deidentifier
```

No administrator installation is required for development or for a packaged
portable build.

## Tests

The automated tests create only synthetic EDF fixtures:

```bash
python -m pytest
```

Never add a clinical EDF, a real filename-to-study-ID mapping, or a diagnostic
log to this directory, a Git commit, or a GitHub Actions artifact. The local
`.gitignore` rejects common forms of those files, but it is not a substitute
for reviewing staged changes.

## Build locally

Install the pinned build dependencies and run PyInstaller on the target
operating system:

```bash
python -m pip install -e ".[test,build]"
python -m pytest
python -m PyInstaller --noconfirm --clean edf_deidentifier.spec
```

PyInstaller is not a cross-compiler. A Windows build must be made on Windows,
an Apple Silicon build on arm64 macOS, and an Intel build on Intel macOS. The
outputs are:

- Windows: `dist/EDF Deidentifier/EDF Deidentifier.exe` plus its adjacent
  dependency folder. Keep the entire `EDF Deidentifier` directory together.
- macOS: `dist/EDF Deidentifier.app`.

These are one-folder/windowed bundles; they do not require users to install
Python or Qt. `THIRD_PARTY_NOTICES.md` is included in the bundle and must be
kept with redistributed copies. The packaged targets are Windows 11 x64 and
macOS 13 or newer, with separate native Apple Silicon and Intel builds.

On macOS, clear Finder/resource-fork metadata and archive the `.app` with
`ditto --norsrc`, not an ordinary recursive copy. This preserves bundle
symlinks and permissions without adding metadata that invalidates strict
code-signature verification after extraction:

```bash
xattr -cr "dist/EDF Deidentifier.app"
codesign --verify --deep --strict "dist/EDF Deidentifier.app"
ditto -c -k --norsrc --keepParent \
  "dist/EDF Deidentifier.app" "EDF-Deidentifier-macOS.zip"
```

## Build all three downloadable packages on GitHub

The repository-root workflow
`.github/workflows/build-edf-deidentifier.yml` runs **only** when manually
dispatched. In GitHub:

1. Open **Actions** → **Build EDF Deidentifier**.
2. Choose **Run workflow**.
3. When all three matrix jobs pass, download:
   - `EDF-Deidentifier-Windows-x64.zip`
   - `EDF-Deidentifier-macOS-arm64.zip`
   - `EDF-Deidentifier-macOS-Intel.zip`

Each job installs pinned PySide6 and PyInstaller versions, runs the synthetic
pytest suite, builds on its native GitHub-hosted runner, creates a platform
ZIP, and uploads that exact ZIP. The workflow never reads the repository's
ignored clinical `EDFs/` folder and must contain no real EDF fixture.

## Unsigned-build warnings

The initial packages have no trusted publisher signature. The Windows
executable is unsigned. PyInstaller may apply the ad-hoc signature required to
assemble a runnable Apple Silicon bundle, but neither macOS build is signed
with an Apple Developer ID or notarized:

- **Windows 11:** Microsoft Defender SmartScreen may show “Windows protected
  your PC.” After independently verifying that the ZIP came from the expected
  repository workflow, an authorized user may choose **More info** → **Run
  anyway** if institutional policy permits it.
- **macOS:** Gatekeeper may say that Apple cannot check the application for
  malicious software or that the developer cannot be verified. After
  independently verifying the download, an authorized user may control-click
  the app and choose **Open**, or use **System Settings** → **Privacy &
  Security** → **Open Anyway**, if institutional policy permits it.

Managed hospital systems may prohibit unsigned applications entirely. In that
case, have institutional IT sign/approve the Windows package and sign and
notarize the macOS packages; do not bypass device policy.

See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for redistributed runtime
licenses.
