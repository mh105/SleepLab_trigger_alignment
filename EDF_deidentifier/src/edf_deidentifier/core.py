"""Byte-preserving EDF de-identification primitives.

Only the EDF patient-identification field (bytes 8 through 87) is changed.
Every other byte is verified before the replacement file is committed.
"""

from __future__ import annotations

import errno
import hashlib
import math
import os
import re
import shutil
import stat
import sys
import tempfile
import uuid
from collections.abc import Callable, Iterable
from dataclasses import dataclass
from pathlib import Path
from typing import Literal, Protocol, TypeAlias

FIXED_HEADER_BYTES = 256
PATIENT_ID_OFFSET = 8
PATIENT_ID_BYTES = 80
PATIENT_ID_END = PATIENT_ID_OFFSET + PATIENT_ID_BYTES
COPY_CHUNK_BYTES = 4 * 1024 * 1024
TEMP_PREFIX = ".edf-deidentifier-"
TEMP_SUFFIX = ".tmp"
RECOVERY_PREFIX = f"{TEMP_PREFIX}rename-"

_STUDY_ID_PATTERN = re.compile(r"[A-Za-z0-9][A-Za-z0-9_-]{0,39}\Z")
_INTEGER_PATTERN = re.compile(r"[+-]?\d+\Z")
_WINDOWS_RESERVED_BASENAMES = {
    "CON",
    "PRN",
    "AUX",
    "NUL",
    "CLOCK$",
    *(f"COM{number}" for number in range(1, 10)),
    *(f"LPT{number}" for number in range(1, 10)),
}


class CancellationToken(Protocol):
    """The part of ``threading.Event`` used by the core."""

    def is_set(self) -> bool: ...


CancelCheck: TypeAlias = Callable[[], bool] | CancellationToken | None
ProgressCallback: TypeAlias = Callable[[str, int, int], None]
BatchProgressCallback: TypeAlias = Callable[["PreparedJob", str, int, int], None]
ResultStatus: TypeAlias = Literal["completed", "failed", "cancelled", "untouched"]


@dataclass(frozen=True)
class FileSignature:
    """Fields used to detect source replacement or modification."""

    size: int
    mtime_ns: int
    device: int | None
    inode: int | None


@dataclass(frozen=True)
class EdfInfo:
    """Validated EDF metadata needed for de-identification."""

    path: Path
    version: str
    patient_id: str
    local_recording_id: str
    auto_id: str
    header_bytes: int
    number_of_data_records: int
    data_record_duration: float
    number_of_signals: int
    samples_per_record: tuple[int, ...]
    file_size: int
    permissions: int
    signature: FileSignature


class EdfError(Exception):
    """Base class carrying user-facing diagnostic fields."""

    def __init__(
        self,
        message: str,
        *,
        stage: str,
        path: Path | None = None,
        temp_cleanup: str = "not needed",
    ) -> None:
        super().__init__(message)
        self.message = message
        self.stage = stage
        self.path = path
        self.temp_cleanup = temp_cleanup


class EdfValidationError(EdfError):
    """An input is not a safe, supported, complete EDF file."""


class StudyIdError(EdfError):
    """A study ID cannot be represented safely in the header and filename."""


@dataclass(frozen=True)
class PreflightIssue:
    path: Path | None
    message: str


class BatchPreflightError(EdfError):
    """One or more batch-wide checks failed before any file was changed."""

    def __init__(self, issues: Iterable[PreflightIssue]) -> None:
        self.issues = tuple(issues)
        message = "\n".join(issue.message for issue in self.issues)
        super().__init__(message, stage="preflight")


class CancellationError(EdfError):
    """Processing was stopped before the current file was committed."""


class DeidentificationError(EdfError):
    """Copy, verification, commit, or rename failed."""


@dataclass(frozen=True)
class ScanEntry:
    """One top-level ``.edf`` directory entry and its validation outcome."""

    path: Path
    info: EdfInfo | None
    error: EdfError | None

    @property
    def is_valid(self) -> bool:
        return self.info is not None and self.error is None


@dataclass(frozen=True)
class DeidentificationJob:
    path: Path
    study_id: str


@dataclass(frozen=True)
class PreparedJob:
    source_path: Path
    target_path: Path
    study_id: str
    patient_field: bytes
    info: EdfInfo


@dataclass(frozen=True)
class BatchPlan:
    jobs: tuple[PreparedJob, ...]
    folder: Path
    required_free_bytes: int


@dataclass(frozen=True)
class FileResult:
    source_path: Path
    target_path: Path
    study_id: str
    status: ResultStatus
    stage: str
    message: str
    temp_cleanup: str = "not needed"


@dataclass(frozen=True)
class BatchResult:
    results: tuple[FileResult, ...]
    stopped_early: bool

    @property
    def completed_count(self) -> int:
        return sum(result.status == "completed" for result in self.results)

    @property
    def failed_count(self) -> int:
        return sum(result.status == "failed" for result in self.results)

    @property
    def cancelled_count(self) -> int:
        return sum(result.status == "cancelled" for result in self.results)

    @property
    def untouched_count(self) -> int:
        return sum(result.status == "untouched" for result in self.results)


def _absolute_path(path: os.PathLike[str] | str) -> Path:
    return Path(os.path.abspath(os.fspath(path)))


def _signature(file_stat: os.stat_result) -> FileSignature:
    device = file_stat.st_dev if file_stat.st_dev else None
    inode = file_stat.st_ino if file_stat.st_ino else None
    return FileSignature(
        size=file_stat.st_size,
        mtime_ns=file_stat.st_mtime_ns,
        device=device,
        inode=inode,
    )


def _signatures_match(left: FileSignature, right: FileSignature) -> bool:
    if left.size != right.size or left.mtime_ns != right.mtime_ns:
        return False
    if (
        left.device is not None
        and right.device is not None
        and left.device != right.device
    ):
        return False
    return (
        left.inode is None
        or right.inode is None
        or left.inode == right.inode
    )


def _stat_regular_file(path: Path, *, stage: str) -> os.stat_result:
    try:
        file_stat = os.stat(path, follow_symlinks=False)
    except OSError as exc:
        raise EdfValidationError(
            f"Cannot inspect the file: {exc}",
            stage=stage,
            path=path,
        ) from exc
    if stat.S_ISLNK(file_stat.st_mode):
        raise EdfValidationError(
            "Symbolic links are not supported.",
            stage=stage,
            path=path,
        )
    if not stat.S_ISREG(file_stat.st_mode):
        raise EdfValidationError(
            "The directory entry is not a regular file.",
            stage=stage,
            path=path,
        )
    return file_stat


def _open_source(path: Path, *, stage: str):
    flags = os.O_RDONLY
    if hasattr(os, "O_BINARY"):
        flags |= os.O_BINARY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(path, flags)
    except OSError as exc:
        message = (
            "Symbolic links are not supported."
            if exc.errno == errno.ELOOP
            else f"Cannot open the file: {exc}"
        )
        raise EdfValidationError(message, stage=stage, path=path) from exc

    try:
        opened_stat = os.fstat(descriptor)
        path_stat = _stat_regular_file(path, stage=stage)
        if not stat.S_ISREG(opened_stat.st_mode) or not _signatures_match(
            _signature(opened_stat), _signature(path_stat)
        ):
            raise EdfValidationError(
                "The file changed while it was being opened.",
                stage=stage,
                path=path,
            )
        return os.fdopen(descriptor, "rb"), opened_stat
    except Exception:
        os.close(descriptor)
        raise


def _read_exact(file_object, byte_count: int, *, field: str, path: Path) -> bytes:
    data = file_object.read(byte_count)
    if len(data) != byte_count:
        raise EdfValidationError(
            f"The {field} is truncated.",
            stage="validate header",
            path=path,
        )
    return data


def _decode_ascii_field(
    data: bytes,
    *,
    field: str,
    path: Path,
    allow_empty: bool = False,
) -> str:
    if any(byte < 0x20 or byte > 0x7E for byte in data):
        raise EdfValidationError(
            f"The {field} contains non-printable or non-ASCII bytes.",
            stage="validate header",
            path=path,
        )
    value = data.decode("ascii").rstrip()
    if not allow_empty and not value:
        raise EdfValidationError(
            f"The {field} is empty.",
            stage="validate header",
            path=path,
        )
    return value


def _parse_integer_field(
    data: bytes,
    *,
    field: str,
    path: Path,
) -> int:
    value = _decode_ascii_field(data, field=field, path=path).strip()
    if not _INTEGER_PATTERN.fullmatch(value):
        raise EdfValidationError(
            f"The {field} is not an integer.",
            stage="validate header",
            path=path,
        )
    return int(value)


def _extract_auto_id(local_recording_id: str, *, path: Path) -> str:
    tokens = local_recording_id.split()
    if len(tokens) < 3 or tokens[0] != "Startdate":
        raise EdfValidationError(
            "The local recording ID must start with 'Startdate' and contain "
            "the system-generated auto ID as its third token.",
            stage="validate header",
            path=path,
        )
    auto_id = tokens[2]
    try:
        encoded = auto_id.encode("ascii")
    except UnicodeEncodeError as exc:
        raise EdfValidationError(
            "The system-generated auto ID is not ASCII.",
            stage="validate header",
            path=path,
        ) from exc
    if not encoded or any(byte <= 0x20 or byte > 0x7E for byte in encoded):
        raise EdfValidationError(
            "The system-generated auto ID must be printable ASCII without spaces.",
            stage="validate header",
            path=path,
        )
    return auto_id


def inspect_edf(path: os.PathLike[str] | str) -> EdfInfo:
    """Parse and validate a closed EDF file without reading its signal data."""

    source_path = _absolute_path(path)
    initial_stat = _stat_regular_file(source_path, stage="validate header")
    if initial_stat.st_size < FIXED_HEADER_BYTES:
        raise EdfValidationError(
            "The EDF fixed header is truncated.",
            stage="validate header",
            path=source_path,
        )

    file_object, opened_stat = _open_source(source_path, stage="validate header")
    with file_object:
        fixed_header = _read_exact(
            file_object,
            FIXED_HEADER_BYTES,
            field="EDF fixed header",
            path=source_path,
        )
        version = _decode_ascii_field(
            fixed_header[0:8],
            field="EDF version",
            path=source_path,
        ).strip()
        if version != "0":
            raise EdfValidationError(
                "Only standard EDF/EDF+ files with version '0' are supported.",
                stage="validate header",
                path=source_path,
            )

        patient_id = _decode_ascii_field(
            fixed_header[PATIENT_ID_OFFSET:PATIENT_ID_END],
            field="patient ID",
            path=source_path,
            allow_empty=True,
        )
        local_recording_id = _decode_ascii_field(
            fixed_header[88:168],
            field="local recording ID",
            path=source_path,
        )
        auto_id = _extract_auto_id(local_recording_id, path=source_path)

        _decode_ascii_field(
            fixed_header[168:176],
            field="recording start date",
            path=source_path,
        )
        _decode_ascii_field(
            fixed_header[176:184],
            field="recording start time",
            path=source_path,
        )
        header_bytes = _parse_integer_field(
            fixed_header[184:192],
            field="header byte count",
            path=source_path,
        )
        _decode_ascii_field(
            fixed_header[192:236],
            field="reserved fixed-header field",
            path=source_path,
            allow_empty=True,
        )
        number_of_data_records = _parse_integer_field(
            fixed_header[236:244],
            field="number of data records",
            path=source_path,
        )
        if number_of_data_records == -1:
            raise EdfValidationError(
                "EDF files with an unknown data-record count (-1) are not "
                "supported; close/export the recording before processing it.",
                stage="validate header",
                path=source_path,
            )
        if number_of_data_records < 0:
            raise EdfValidationError(
                "The number of data records cannot be negative.",
                stage="validate header",
                path=source_path,
            )

        duration_text = _decode_ascii_field(
            fixed_header[244:252],
            field="data-record duration",
            path=source_path,
        ).strip()
        try:
            data_record_duration = float(duration_text)
        except ValueError as exc:
            raise EdfValidationError(
                "The data-record duration is not numeric.",
                stage="validate header",
                path=source_path,
            ) from exc
        if not math.isfinite(data_record_duration) or data_record_duration <= 0:
            raise EdfValidationError(
                "The data-record duration must be a positive finite number.",
                stage="validate header",
                path=source_path,
            )

        number_of_signals = _parse_integer_field(
            fixed_header[252:256],
            field="number of signals",
            path=source_path,
        )
        if number_of_signals <= 0:
            raise EdfValidationError(
                "The number of signals must be positive.",
                stage="validate header",
                path=source_path,
            )

        expected_header_bytes = FIXED_HEADER_BYTES * (number_of_signals + 1)
        if header_bytes != expected_header_bytes:
            raise EdfValidationError(
                "The header byte count does not match the number of signals.",
                stage="validate header",
                path=source_path,
            )
        if header_bytes > opened_stat.st_size:
            raise EdfValidationError(
                "The EDF signal header is truncated.",
                stage="validate header",
                path=source_path,
            )

        signal_header = _read_exact(
            file_object,
            header_bytes - FIXED_HEADER_BYTES,
            field="EDF signal header",
            path=source_path,
        )
        _decode_ascii_field(
            signal_header,
            field="EDF signal header",
            path=source_path,
            allow_empty=True,
        )
        samples_offset = 216 * number_of_signals
        samples_per_record = tuple(
            _parse_integer_field(
                signal_header[
                    samples_offset + signal_index * 8 :
                    samples_offset + (signal_index + 1) * 8
                ],
                field=f"samples per record for signal {signal_index + 1}",
                path=source_path,
            )
            for signal_index in range(number_of_signals)
        )
        if any(sample_count <= 0 for sample_count in samples_per_record):
            raise EdfValidationError(
                "Samples per record must be positive for every signal.",
                stage="validate header",
                path=source_path,
            )

        expected_file_size = header_bytes + (
            number_of_data_records * sum(samples_per_record) * 2
        )
        if opened_stat.st_size != expected_file_size:
            raise EdfValidationError(
                "The EDF file size does not match its header geometry.",
                stage="validate header",
                path=source_path,
            )

        final_open_stat = os.fstat(file_object.fileno())

    final_path_stat = _stat_regular_file(source_path, stage="validate header")
    opened_signature = _signature(opened_stat)
    if (
        not _signatures_match(_signature(initial_stat), opened_signature)
        or not _signatures_match(opened_signature, _signature(final_open_stat))
        or not _signatures_match(opened_signature, _signature(final_path_stat))
    ):
        raise EdfValidationError(
            "The EDF changed while its header was being validated.",
            stage="validate header",
            path=source_path,
        )

    return EdfInfo(
        path=source_path,
        version=version,
        patient_id=patient_id,
        local_recording_id=local_recording_id,
        auto_id=auto_id,
        header_bytes=header_bytes,
        number_of_data_records=number_of_data_records,
        data_record_duration=data_record_duration,
        number_of_signals=number_of_signals,
        samples_per_record=samples_per_record,
        file_size=opened_stat.st_size,
        permissions=stat.S_IMODE(opened_stat.st_mode),
        signature=opened_signature,
    )


def scan_folder(folder: os.PathLike[str] | str) -> tuple[ScanEntry, ...]:
    """Inspect only top-level files whose extension case-insensitively is EDF."""

    folder_path = _absolute_path(folder)
    try:
        folder_stat = os.stat(folder_path, follow_symlinks=False)
    except OSError as exc:
        raise EdfValidationError(
            f"Cannot open the selected folder: {exc}",
            stage="scan",
            path=folder_path,
        ) from exc
    if stat.S_ISLNK(folder_stat.st_mode) or not stat.S_ISDIR(folder_stat.st_mode):
        raise EdfValidationError(
            "The selected path must be a real directory, not a symbolic link.",
            stage="scan",
            path=folder_path,
        )

    try:
        with os.scandir(folder_path) as entries:
            candidates = sorted(
                (
                    folder_path / entry.name
                    for entry in entries
                    if Path(entry.name).suffix.casefold() == ".edf"
                ),
                key=lambda candidate: (candidate.name.casefold(), candidate.name),
            )
    except OSError as exc:
        raise EdfValidationError(
            f"Cannot scan the selected folder: {exc}",
            stage="scan",
            path=folder_path,
        ) from exc

    results: list[ScanEntry] = []
    for candidate in candidates:
        try:
            results.append(
                ScanEntry(path=candidate, info=inspect_edf(candidate), error=None)
            )
        except EdfError as exc:
            results.append(ScanEntry(path=candidate, info=None, error=exc))
    return tuple(results)


def validate_study_id(study_id: str) -> str:
    """Return a valid study ID unchanged or raise ``StudyIdError``."""

    if not isinstance(study_id, str) or not _STUDY_ID_PATTERN.fullmatch(study_id):
        raise StudyIdError(
            "Study ID must be 1-40 ASCII characters, start with a letter or "
            "digit, and contain only letters, digits, underscores, or hyphens.",
            stage="validate study ID",
        )
    if study_id.upper() in _WINDOWS_RESERVED_BASENAMES:
        raise StudyIdError(
            "Study ID is a reserved Windows filename.",
            stage="validate study ID",
        )
    return study_id


def _make_patient_field(auto_id: str, study_id: str, *, path: Path) -> bytes:
    patient_id = f"{auto_id} X 01-JAN-1999 {study_id}"
    try:
        encoded = patient_id.encode("ascii")
    except UnicodeEncodeError as exc:
        raise StudyIdError(
            "The replacement patient ID is not ASCII.",
            stage="preflight",
            path=path,
        ) from exc
    if len(encoded) > PATIENT_ID_BYTES:
        raise StudyIdError(
            "The system-generated auto ID and study ID do not fit in the "
            "80-byte EDF patient field.",
            stage="preflight",
            path=path,
        )
    return encoded.ljust(PATIENT_ID_BYTES, b" ")


def _same_file(left: Path, right: Path) -> bool:
    try:
        return os.path.samefile(left, right)
    except OSError:
        return False


def _target_conflict(source: Path, target: Path) -> Path | None:
    try:
        entries = os.scandir(target.parent)
    except OSError:
        return target
    with entries:
        for entry in entries:
            if entry.name.casefold() != target.name.casefold():
                continue
            existing = target.parent / entry.name
            # The source's own directory entry is allowed (including a
            # case-only rename on a case-insensitive filesystem). A different
            # hard-link entry must still count as an existing target.
            if entry.name == source.name:
                continue
            return existing
    return None


def preflight_batch(jobs: Iterable[DeidentificationJob]) -> BatchPlan:
    """Validate an entire batch, including cross-platform filename collisions."""

    requested_jobs = tuple(jobs)
    if not requested_jobs:
        raise BatchPreflightError(
            [PreflightIssue(None, "Select at least one EDF file.")]
        )

    issues: list[PreflightIssue] = []
    partial: list[tuple[Path, str, EdfInfo, bytes, Path]] = []
    seen_sources: dict[str, Path] = {}
    folders: set[Path] = set()

    for requested in requested_jobs:
        source = _absolute_path(requested.path)
        folders.add(source.parent)
        source_key = source.name.casefold()
        if source_key in seen_sources:
            issues.append(
                PreflightIssue(
                    source,
                    "The same source filename appears more than once in the batch.",
                )
            )
            continue
        seen_sources[source_key] = source

        try:
            study_id = validate_study_id(requested.study_id)
            info = inspect_edf(source)
            patient_field = _make_patient_field(
                info.auto_id,
                study_id,
                path=source,
            )
        except EdfError as exc:
            issues.append(PreflightIssue(source, exc.message))
            continue

        target = source.with_name(f"{study_id}.edf")
        partial.append((source, study_id, info, patient_field, target))

    if len(folders) != 1:
        issues.append(
            PreflightIssue(
                None,
                "All selected EDF files must be in the same top-level folder.",
            )
        )
    else:
        selected_folder = next(iter(folders))
        try:
            directory_entries = os.scandir(selected_folder)
        except OSError:
            directory_entries = None
        if directory_entries is not None:
            with directory_entries:
                recoveries = sorted(
                    entry.name
                    for entry in directory_entries
                    if entry.name.startswith(RECOVERY_PREFIX)
                    and entry.name.endswith(TEMP_SUFFIX)
                )
            if recoveries:
                issues.append(
                    PreflightIssue(
                        selected_folder,
                        f"An unresolved recovery file exists: "
                        f"{recoveries[0]}. Resolve it before starting another "
                        f"batch.",
                    )
                )

    seen_targets: dict[str, Path] = {}
    for source, _study_id, _info, _patient_field, target in partial:
        target_key = target.name.casefold()
        previous = seen_targets.get(target_key)
        if previous is not None:
            issues.append(
                PreflightIssue(
                    source,
                    f"Output filename conflicts with another selected row: "
                    f"{target.name}",
                )
            )
        else:
            seen_targets[target_key] = source

        conflict = _target_conflict(source, target)
        if conflict is not None:
            issues.append(
                PreflightIssue(
                    source,
                    f"Output filename already exists: {conflict.name}",
                )
            )

    required_free_bytes = max(
        (info.file_size for _source, _study_id, info, _field, _target in partial),
        default=0,
    )
    folder = next(iter(folders)) if len(folders) == 1 else Path()
    if folder and folder.is_dir():
        try:
            available = shutil.disk_usage(folder).free
        except OSError as exc:
            issues.append(
                PreflightIssue(
                    folder,
                    f"Cannot check free space in the selected folder: {exc}",
                )
            )
        else:
            if available < required_free_bytes:
                issues.append(
                    PreflightIssue(
                        folder,
                        "There is not enough free space for a safe temporary copy.",
                    )
                )

    if issues:
        raise BatchPreflightError(issues)

    prepared = tuple(
        PreparedJob(
            source_path=source,
            target_path=target,
            study_id=study_id,
            patient_field=patient_field,
            info=info,
        )
        for source, study_id, info, patient_field, target in partial
    )
    return BatchPlan(
        jobs=prepared,
        folder=folder,
        required_free_bytes=required_free_bytes,
    )


def _cancel_requested(cancel: CancelCheck) -> bool:
    if cancel is None:
        return False
    if callable(cancel):
        return bool(cancel())
    return bool(cancel.is_set())


def _report_progress(
    callback: ProgressCallback | None,
    stage: str,
    completed: int,
    total: int,
) -> None:
    if callback is None:
        return
    try:
        callback(stage, completed, total)
    except Exception:  # noqa: BLE001 - progress is an untrusted UI sink
        # A UI progress sink must never determine file-integrity behavior.
        return


def _cleanup_temp(temp_path: Path | None) -> str:
    if temp_path is None or not os.path.lexists(temp_path):
        return "not needed"
    try:
        temp_path.unlink()
    except OSError as exc:
        return f"failed: {exc}"
    return "removed"


def _ensure_source_unchanged(job: PreparedJob, *, stage: str) -> None:
    source_stat = _stat_regular_file(job.source_path, stage=stage)
    if not _signatures_match(job.info.signature, _signature(source_stat)):
        raise DeidentificationError(
            "The source EDF changed after preflight; it was not replaced.",
            stage=stage,
            path=job.source_path,
        )


def _ensure_target_available(job: PreparedJob, *, stage: str) -> None:
    conflict = _target_conflict(job.source_path, job.target_path)
    if conflict is not None:
        raise DeidentificationError(
            f"Output filename appeared after preflight: {conflict.name}",
            stage=stage,
            path=job.source_path,
        )


def _verify_temporary_copy(
    temp_path: Path,
    *,
    expected_patient_field: bytes,
    expected_unchanged_hash: bytes,
    expected_size: int,
    cancel: CancelCheck,
    progress: ProgressCallback | None,
) -> FileSignature:
    unchanged_hash = hashlib.sha256()
    bytes_read = 0
    _report_progress(progress, "verify", 0, expected_size)
    temporary, opened_stat = _open_source(temp_path, stage="verify")
    with temporary:
        fixed_header = temporary.read(FIXED_HEADER_BYTES)
        if len(fixed_header) != FIXED_HEADER_BYTES:
            raise DeidentificationError(
                "The temporary EDF is truncated.",
                stage="verify",
                path=temp_path,
            )
        if fixed_header[PATIENT_ID_OFFSET:PATIENT_ID_END] != expected_patient_field:
            raise DeidentificationError(
                "The temporary EDF patient field does not match the requested value.",
                stage="verify",
                path=temp_path,
            )
        unchanged_hash.update(fixed_header[:PATIENT_ID_OFFSET])
        unchanged_hash.update(fixed_header[PATIENT_ID_END:])
        bytes_read = len(fixed_header)

        while True:
            if _cancel_requested(cancel):
                raise CancellationError(
                    "Stopped during read-back verification; the source is unchanged.",
                    stage="verify",
                    path=temp_path,
                )
            chunk = temporary.read(COPY_CHUNK_BYTES)
            if not chunk:
                break
            unchanged_hash.update(chunk)
            bytes_read += len(chunk)

        final_stat = os.fstat(temporary.fileno())
        path_stat = _stat_regular_file(temp_path, stage="verify")
        if not _signatures_match(
            _signature(opened_stat),
            _signature(final_stat),
        ) or not _signatures_match(
            _signature(final_stat),
            _signature(path_stat),
        ):
            raise DeidentificationError(
                "The verified file changed during read-back verification.",
                stage="verify",
                path=temp_path,
            )

    if bytes_read != expected_size:
        raise DeidentificationError(
            "The temporary EDF size changed during read-back verification.",
            stage="verify",
            path=temp_path,
        )
    if unchanged_hash.digest() != expected_unchanged_hash:
        raise DeidentificationError(
            "Read-back verification found changed bytes outside the patient field.",
            stage="verify",
            path=temp_path,
        )
    return _signature(path_stat)


def _fsync_directory(folder: Path) -> None:
    if os.name == "nt":
        return
    descriptor = os.open(folder, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def _unique_intermediate_path(folder: Path) -> Path:
    while True:
        candidate = folder / f"{TEMP_PREFIX}rename-{uuid.uuid4().hex}{TEMP_SUFFIX}"
        if not os.path.lexists(candidate):
            return candidate


def _native_rename_noreplace(source: Path, target: Path) -> bool:
    """Use a platform-native exclusive rename when one is available."""

    if os.name == "nt":
        os.rename(source, target)
        return True

    if sys.platform == "darwin":
        import ctypes

        renamex_np = ctypes.CDLL(None, use_errno=True).renamex_np
        renamex_np.argtypes = (
            ctypes.c_char_p,
            ctypes.c_char_p,
            ctypes.c_uint,
        )
        renamex_np.restype = ctypes.c_int
        ctypes.set_errno(0)
        if renamex_np(
            os.fsencode(source),
            os.fsencode(target),
            0x00000004,  # RENAME_EXCL
        ) == 0:
            return True
        error_number = ctypes.get_errno() or errno.EIO
        raise OSError(
            error_number,
            f"exclusive rename failed: {os.strerror(error_number)}",
            os.fspath(target),
        )

    if sys.platform.startswith("linux"):
        import ctypes

        libc = ctypes.CDLL(None, use_errno=True)
        try:
            renameat2 = libc.renameat2
        except AttributeError:
            return False
        renameat2.argtypes = (
            ctypes.c_int,
            ctypes.c_char_p,
            ctypes.c_int,
            ctypes.c_char_p,
            ctypes.c_uint,
        )
        renameat2.restype = ctypes.c_int
        ctypes.set_errno(0)
        if renameat2(
            -100,  # AT_FDCWD
            os.fsencode(source),
            -100,
            os.fsencode(target),
            1,  # RENAME_NOREPLACE
        ) == 0:
            return True
        error_number = ctypes.get_errno() or errno.EIO
        if error_number == errno.ENOSYS:
            return False
        raise OSError(
            error_number,
            f"exclusive rename failed: {os.strerror(error_number)}",
            os.fspath(target),
        )

    return False


def _rename_noreplace(source: Path, target: Path) -> None:
    """Rename without ever replacing an existing destination entry."""

    if _native_rename_noreplace(source, target):
        return
    raise OSError(
        errno.ENOTSUP,
        "this platform does not provide a safe exclusive rename",
        os.fspath(target),
    )


def _same_directory_entry(source: Path, target: Path) -> bool:
    if source == target:
        return True
    return os.path.lexists(target) and _same_file(source, target)


def _verify_full_file(
    path: Path,
    *,
    expected_digest: bytes,
    expected_size: int,
    stage: str,
) -> FileSignature:
    digest = hashlib.sha256()
    bytes_read = 0
    file_object, opened_stat = _open_source(path, stage=stage)
    with file_object:
        while True:
            chunk = file_object.read(COPY_CHUNK_BYTES)
            if not chunk:
                break
            digest.update(chunk)
            bytes_read += len(chunk)

        final_stat = os.fstat(file_object.fileno())
        path_stat = _stat_regular_file(path, stage=stage)
        final_signature = _signature(final_stat)
        if not _signatures_match(
            _signature(opened_stat),
            final_signature,
        ) or not _signatures_match(
            final_signature,
            _signature(path_stat),
        ):
            raise DeidentificationError(
                "The source path changed while its identity was verified.",
                stage=stage,
                path=path,
            )

    if bytes_read != expected_size or digest.digest() != expected_digest:
        raise DeidentificationError(
            "The source EDF changed while the safe commit began.",
            stage=stage,
            path=path,
        )
    return final_signature


def _restore_quarantined_path(quarantine: Path, destination: Path) -> str:
    try:
        _rename_noreplace(quarantine, destination)
    except OSError as recovery_error:
        return (
            f"retained at the recovery path {quarantine.name}; automatic "
            f"restoration failed: {recovery_error}"
        )
    return f"restored at {destination.name}"


def _quarantine_expected_source(
    job: PreparedJob,
    *,
    expected_digest: bytes,
    verify_contents: bool = True,
) -> tuple[Path, FileSignature]:
    quarantine = _unique_intermediate_path(job.source_path.parent)
    try:
        _rename_noreplace(job.source_path, quarantine)
    except OSError as exc:
        raise DeidentificationError(
            f"The original filename could not be secured for removal: {exc}",
            stage="rename",
            path=job.source_path,
        ) from exc

    try:
        _fsync_directory(job.source_path.parent)
    except OSError as exc:
        recovery = _restore_quarantined_path(quarantine, job.source_path)
        raise DeidentificationError(
            f"The original filename move could not be made durable. The "
            f"original EDF was {recovery}: {exc}",
            stage="rename",
            path=job.source_path,
        ) from exc

    try:
        if verify_contents:
            verified_signature = _verify_full_file(
                quarantine,
                expected_digest=expected_digest,
                expected_size=job.info.file_size,
                stage="rename",
            )
        else:
            verified_signature = _signature(
                _stat_regular_file(quarantine, stage="rename")
            )
            if not _signatures_match(
                job.info.signature,
                verified_signature,
            ):
                raise DeidentificationError(
                    "The source entry changed as the safe commit began.",
                    stage="rename",
                    path=quarantine,
                )
    except EdfError as exc:
        recovery = _restore_quarantined_path(quarantine, job.source_path)
        raise DeidentificationError(
            f"The source EDF changed while the safe commit began. The "
            f"concurrent entry was not deleted and was {recovery}.",
            stage="rename",
            path=job.source_path,
        ) from exc
    return quarantine, verified_signature


def _remove_quarantined_original(
    quarantine: Path,
    *,
    expected_signature: FileSignature,
    expected_output_signature: FileSignature,
    output_path: Path,
    original_path: Path,
) -> None:
    current_signature = _signature(
        _stat_regular_file(quarantine, stage="rename")
    )
    if not _signatures_match(expected_signature, current_signature):
        recovery = _restore_quarantined_path(quarantine, original_path)
        raise DeidentificationError(
            f"The recovery entry changed before the original could be "
            f"removed. The changed entry was not deleted and was {recovery}. "
            f"The deidentified output remains at {output_path.name}.",
            stage="rename",
            path=original_path,
        )

    current_output_signature = _signature(
        _stat_regular_file(output_path, stage="rename")
    )
    if not _signatures_match(
        expected_output_signature,
        current_output_signature,
    ):
        recovery = _restore_quarantined_path(quarantine, original_path)
        raise DeidentificationError(
            f"The deidentified output changed before the original could be "
            f"removed. The original was {recovery}.",
            stage="rename",
            path=output_path,
        )

    try:
        quarantine.unlink()
    except OSError as exc:
        raise DeidentificationError(
            f"The deidentified output was created at {output_path.name}, but "
            f"the original could not be removed and remains at the recovery "
            f"path {quarantine.name}: {exc}",
            stage="rename",
            path=original_path,
        ) from exc


def _install_verified_output(
    temp_path: Path,
    target_path: Path,
) -> None:
    try:
        _rename_noreplace(temp_path, target_path)
    except OSError as exc:
        raise DeidentificationError(
            f"The deidentified output could not be installed without "
            f"overwriting another file: {exc}",
            stage="commit",
            path=target_path,
        ) from exc


def _restore_after_install_failure(
    quarantine: Path,
    source_path: Path,
    failure: EdfError,
) -> DeidentificationError:
    recovery = _restore_quarantined_path(quarantine, source_path)
    return DeidentificationError(
        f"{failure.message} The original EDF was {recovery}.",
        stage=failure.stage,
        path=source_path,
    )


def deidentify_file(
    job: PreparedJob,
    *,
    cancel: CancelCheck = None,
    progress: ProgressCallback | None = None,
) -> FileResult:
    """Safely de-identify one preflighted EDF and rename it in place."""

    temp_path: Path | None = None
    stage = "copy"
    output_installed = False
    quarantine_path: Path | None = None
    quarantine_signature: FileSignature | None = None
    try:
        if _cancel_requested(cancel):
            raise CancellationError(
                "Stopped before copying; the source is unchanged.",
                stage="copy",
                path=job.source_path,
            )

        current_info = inspect_edf(job.source_path)
        if current_info != job.info:
            raise DeidentificationError(
                "The source EDF changed after preflight; it was not replaced.",
                stage="copy",
                path=job.source_path,
            )
        _ensure_target_available(job, stage="copy")

        descriptor, temp_name = tempfile.mkstemp(
            prefix=TEMP_PREFIX,
            suffix=TEMP_SUFFIX,
            dir=job.source_path.parent,
        )
        temp_path = Path(temp_name)
        try:
            temporary_file = os.fdopen(descriptor, "wb")
        except Exception:
            os.close(descriptor)
            raise
        unchanged_hash = hashlib.sha256()
        source_hash = hashlib.sha256()
        bytes_copied = 0

        try:
            source, opened_stat = _open_source(job.source_path, stage="copy")
        except Exception:
            temporary_file.close()
            raise
        try:
            if not _signatures_match(job.info.signature, _signature(opened_stat)):
                raise DeidentificationError(
                    "The source EDF changed after preflight; it was not replaced.",
                    stage="copy",
                    path=job.source_path,
                )
            with source, temporary_file as temporary:
                fixed_header = source.read(FIXED_HEADER_BYTES)
                if len(fixed_header) != FIXED_HEADER_BYTES:
                    raise DeidentificationError(
                        "The source EDF became truncated during copying.",
                        stage="copy",
                        path=job.source_path,
                    )
                unchanged_hash.update(fixed_header[:PATIENT_ID_OFFSET])
                unchanged_hash.update(fixed_header[PATIENT_ID_END:])
                source_hash.update(fixed_header)
                temporary.write(
                    fixed_header[:PATIENT_ID_OFFSET]
                    + job.patient_field
                    + fixed_header[PATIENT_ID_END:]
                )
                bytes_copied = FIXED_HEADER_BYTES
                _report_progress(
                    progress,
                    "copy",
                    bytes_copied,
                    job.info.file_size,
                )

                while True:
                    if _cancel_requested(cancel):
                        raise CancellationError(
                            "Stopped during copying; the source is unchanged.",
                            stage="copy",
                            path=job.source_path,
                        )
                    chunk = source.read(COPY_CHUNK_BYTES)
                    if not chunk:
                        break
                    unchanged_hash.update(chunk)
                    source_hash.update(chunk)
                    temporary.write(chunk)
                    bytes_copied += len(chunk)
                    _report_progress(
                        progress,
                        "copy",
                        bytes_copied,
                        job.info.file_size,
                    )

                if bytes_copied != job.info.file_size:
                    raise DeidentificationError(
                        "The source EDF size changed during copying.",
                        stage="copy",
                        path=job.source_path,
                    )
                temporary.flush()
                os.fsync(temporary.fileno())
                final_source_stat = os.fstat(source.fileno())
                if not _signatures_match(
                    job.info.signature,
                    _signature(final_source_stat),
                ):
                    raise DeidentificationError(
                        "The source EDF changed during copying; it was not replaced.",
                        stage="copy",
                        path=job.source_path,
                    )
        except Exception:
            source.close()
            temporary_file.close()
            raise

        stage = "verify"
        _verify_temporary_copy(
            temp_path,
            expected_patient_field=job.patient_field,
            expected_unchanged_hash=unchanged_hash.digest(),
            expected_size=job.info.file_size,
            cancel=cancel,
            progress=progress,
        )
        _ensure_source_unchanged(job, stage="verify")

        if _cancel_requested(cancel):
            raise CancellationError(
                "Stopped before committing; the source is unchanged.",
                stage="verify",
                path=job.source_path,
            )

        os.chmod(temp_path, job.info.permissions)
        temporary_stat = temp_path.stat()
        os.utime(
            temp_path,
            ns=(temporary_stat.st_atime_ns, job.info.signature.mtime_ns),
        )
        verified_temp_signature = _signature(
            _stat_regular_file(temp_path, stage="verify")
        )

        stage = "commit"
        if _cancel_requested(cancel):
            raise CancellationError(
                "Stopped before committing; the source is unchanged.",
                stage="commit",
                path=job.source_path,
            )
        _ensure_target_available(job, stage="commit")
        _ensure_source_unchanged(job, stage="commit")

        same_entry = _same_directory_entry(
            job.source_path,
            job.target_path,
        )
        if same_entry:
            quarantine_path, quarantine_signature = _quarantine_expected_source(
                job,
                expected_digest=source_hash.digest(),
                verify_contents=False,
            )

        try:
            _install_verified_output(
                temp_path,
                job.target_path,
            )
        except EdfError as exc:
            if quarantine_path is not None:
                restored_error = _restore_after_install_failure(
                    quarantine_path,
                    job.source_path,
                    exc,
                )
                if not os.path.lexists(quarantine_path):
                    quarantine_path = None
                raise restored_error from exc
            raise
        temp_path = None
        output_installed = True
        target_stat = _stat_regular_file(job.target_path, stage="commit")
        if not _signatures_match(
            verified_temp_signature,
            _signature(target_stat),
        ):
            raise DeidentificationError(
                "The installed output is not the verified temporary file. "
                f"The original remains available at "
                f"{quarantine_path.name if quarantine_path else job.source_path.name}.",
                stage="commit",
                path=job.target_path,
            )
        try:
            _fsync_directory(job.target_path.parent)
        except OSError as exc:
            original_location = (
                f"the recovery path {quarantine_path.name}"
                if quarantine_path is not None
                else f"the original path {job.source_path.name}"
            )
            raise DeidentificationError(
                f"The output was installed at {job.target_path.name}, but its "
                f"directory entry could not be made durable. The original "
                f"remains at {original_location}: {exc}",
                stage="commit",
                path=job.target_path,
            ) from exc
        _report_progress(
            progress,
            "commit",
            job.info.file_size,
            job.info.file_size,
        )

        stage = "rename"
        _report_progress(
            progress,
            "rename",
            0,
            job.info.file_size,
        )
        if same_entry:
            try:
                quarantine_signature = _verify_full_file(
                    quarantine_path,
                    expected_digest=source_hash.digest(),
                    expected_size=job.info.file_size,
                    stage="rename",
                )
            except EdfError as exc:
                recovery = _restore_quarantined_path(
                    quarantine_path,
                    job.source_path,
                )
                raise DeidentificationError(
                    f"The source EDF changed while the safe commit began. "
                    f"The changed entry was not deleted and was {recovery}.",
                    stage="rename",
                    path=job.source_path,
                ) from exc

        if quarantine_path is None:
            try:
                (
                    quarantine_path,
                    quarantine_signature,
                ) = _quarantine_expected_source(
                        job,
                        expected_digest=source_hash.digest(),
                )
            except EdfError as exc:
                raise DeidentificationError(
                    f"The deidentified output was created at "
                    f"{job.target_path.name}, but the original filename could "
                    f"not be removed safely: {exc.message}",
                    stage=exc.stage,
                    path=job.source_path,
                ) from exc

        try:
            verified_target_signature = _verify_temporary_copy(
                job.target_path,
                expected_patient_field=job.patient_field,
                expected_unchanged_hash=unchanged_hash.digest(),
                expected_size=job.info.file_size,
                cancel=None,
                progress=None,
            )
        except EdfError as exc:
            recovery = _restore_quarantined_path(
                quarantine_path,
                job.source_path,
            )
            if not os.path.lexists(quarantine_path):
                quarantine_path = None
            raise DeidentificationError(
                f"The output was installed at {job.target_path.name}, but "
                f"final verification failed: {exc.message} The original "
                f"was {recovery}.",
                stage="verify installed output",
                path=job.source_path,
            ) from exc

        try:
            _fsync_directory(job.target_path.parent)
        except OSError as exc:
            raise DeidentificationError(
                f"The output was verified at {job.target_path.name}, but its "
                f"directory entry could not be made durable. The original "
                f"remains at the recovery path {quarantine_path.name}: {exc}",
                stage="commit",
                path=job.target_path,
            ) from exc

        assert quarantine_signature is not None
        _remove_quarantined_original(
            quarantine_path,
            expected_signature=quarantine_signature,
            expected_output_signature=verified_target_signature,
            output_path=job.target_path,
            original_path=job.source_path,
        )
        quarantine_path = None
        try:
            _fsync_directory(job.target_path.parent)
        except OSError as exc:
            raise DeidentificationError(
                f"The deidentified output remains at {job.target_path.name}, "
                f"but final directory synchronization failed after the "
                f"original was removed: {exc}",
                stage="rename",
                path=job.target_path,
            ) from exc

        source_reappeared = (
            not same_entry and os.path.lexists(job.source_path)
        )
        if source_reappeared:
            raise DeidentificationError(
                f"The deidentified output was created at "
                f"{job.target_path.name}, but another entry appeared at the "
                f"original filename during commit. That concurrent entry was "
                f"not removed.",
                stage="rename",
                path=job.source_path,
            )

        return FileResult(
            source_path=job.source_path,
            target_path=job.target_path,
            study_id=job.study_id,
            status="completed",
            stage="completed",
            message="Deidentified and renamed successfully.",
        )
    except EdfError as exc:
        cleanup = _cleanup_temp(temp_path)
        if exc.temp_cleanup == "not needed":
            exc.temp_cleanup = cleanup
        raise
    except Exception as exc:
        cleanup = _cleanup_temp(temp_path)
        state = (
            "A deidentified output may already exist."
            if output_installed
            else "The source was not replaced."
        )
        raise DeidentificationError(
            f"{state} {exc}",
            stage=stage,
            path=job.source_path,
            temp_cleanup=cleanup,
        ) from exc


def process_batch(
    plan: BatchPlan,
    *,
    cancel: CancelCheck = None,
    progress: BatchProgressCallback | None = None,
) -> BatchResult:
    """Process sequentially and report completed, failed, and untouched rows."""

    results: list[FileResult] = []
    stopped_early = False

    for job_index, job in enumerate(plan.jobs):
        if _cancel_requested(cancel):
            stopped_early = True
            results.extend(
                FileResult(
                    source_path=remaining.source_path,
                    target_path=remaining.target_path,
                    study_id=remaining.study_id,
                    status="untouched",
                    stage="not started",
                    message="Not started because the batch was stopped.",
                )
                for remaining in plan.jobs[job_index:]
            )
            break

        per_file_progress = (
            None
            if progress is None
            else lambda stage, completed, total, current=job: progress(
                current,
                stage,
                completed,
                total,
            )
        )
        try:
            results.append(
                deidentify_file(
                    job,
                    cancel=cancel,
                    progress=per_file_progress,
                )
            )
        except CancellationError as exc:
            stopped_early = True
            results.append(
                FileResult(
                    source_path=job.source_path,
                    target_path=job.target_path,
                    study_id=job.study_id,
                    status="cancelled",
                    stage=exc.stage,
                    message=exc.message,
                    temp_cleanup=exc.temp_cleanup,
                )
            )
        except EdfError as exc:
            stopped_early = True
            results.append(
                FileResult(
                    source_path=job.source_path,
                    target_path=job.target_path,
                    study_id=job.study_id,
                    status="failed",
                    stage=exc.stage,
                    message=exc.message,
                    temp_cleanup=exc.temp_cleanup,
                )
            )

        if stopped_early:
            results.extend(
                FileResult(
                    source_path=remaining.source_path,
                    target_path=remaining.target_path,
                    study_id=remaining.study_id,
                    status="untouched",
                    stage="not started",
                    message="Not started after the preceding row stopped the batch.",
                )
                for remaining in plan.jobs[job_index + 1 :]
            )
            break

    return BatchResult(results=tuple(results), stopped_early=stopped_early)
