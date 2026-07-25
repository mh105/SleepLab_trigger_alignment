from __future__ import annotations

import errno
import os
import stat
from pathlib import Path
from types import SimpleNamespace

import pytest

from edf_deidentifier import (
    BatchPreflightError,
    CancellationError,
    DeidentificationError,
    DeidentificationJob,
    EdfValidationError,
    StudyIdError,
    core,
    deidentify_file,
    inspect_edf,
    preflight_batch,
    process_batch,
    scan_folder,
    validate_study_id,
)


def _field(value: object, width: int) -> bytes:
    encoded = str(value).encode("ascii")
    assert len(encoded) <= width
    return encoded.ljust(width, b" ")


def _signal_fields(values: tuple[object, ...], width: int) -> bytes:
    return b"".join(_field(value, width) for value in values)


def make_synthetic_edf(
    path: Path,
    *,
    patient_id: str = "123456 M 12-SEP-1950 SYNTHETIC_PERSON",
    local_recording_id: str = "Startdate 25-FEB-2026 AUTO85061915252301 X DEVICE_01",
    number_of_records: int = 2,
    samples_per_record: tuple[int, ...] = (2, 1),
    records_field: int | None = None,
) -> bytes:
    signal_count = len(samples_per_record)
    header_bytes = 256 * (signal_count + 1)
    fixed_header = b"".join(
        (
            _field("0", 8),
            _field(patient_id, 80),
            _field(local_recording_id, 80),
            _field("25.02.26", 8),
            _field("21.01.50", 8),
            _field(header_bytes, 8),
            _field("EDF+C", 44),
            _field(
                number_of_records if records_field is None else records_field,
                8,
            ),
            _field("1", 8),
            _field(signal_count, 4),
        )
    )
    assert len(fixed_header) == 256

    labels = tuple(f"Signal {index + 1}" for index in range(signal_count))
    signal_header = b"".join(
        (
            _signal_fields(labels, 16),
            _signal_fields(("",) * signal_count, 80),
            _signal_fields(("uV",) * signal_count, 8),
            _signal_fields(("-100",) * signal_count, 8),
            _signal_fields(("100",) * signal_count, 8),
            _signal_fields(("-32768",) * signal_count, 8),
            _signal_fields(("32767",) * signal_count, 8),
            _signal_fields(("synthetic",) * signal_count, 80),
            _signal_fields(samples_per_record, 8),
            _signal_fields(("",) * signal_count, 32),
        )
    )
    assert len(signal_header) == 256 * signal_count

    data_byte_count = number_of_records * sum(samples_per_record) * 2
    signal_data = bytes(index % 251 for index in range(data_byte_count))
    contents = fixed_header + signal_header + signal_data
    path.write_bytes(contents)
    return contents


def _temp_files(folder: Path) -> list[Path]:
    return list(folder.glob(f"{core.TEMP_PREFIX}*"))


def test_inspect_edf_parses_closed_file_and_exact_geometry(tmp_path: Path) -> None:
    source = tmp_path / "SYNTHETIC_PERSON.edf"
    contents = make_synthetic_edf(source)

    info = inspect_edf(source)

    assert info.auto_id == "AUTO85061915252301"
    assert info.local_recording_id.startswith("Startdate")
    assert info.header_bytes == 768
    assert info.number_of_data_records == 2
    assert info.number_of_signals == 2
    assert info.samples_per_record == (2, 1)
    assert info.file_size == len(contents)


@pytest.mark.parametrize(
    "study_id",
    ("sas_023", "A", "a-b_C", "9" * 40),
)
def test_validate_study_id_accepts_cross_platform_names(study_id: str) -> None:
    assert validate_study_id(study_id) == study_id


@pytest.mark.parametrize(
    "study_id",
    (
        "",
        "_starts_with_underscore",
        "-starts-with-hyphen",
        "has space",
        "has.period",
        "é",
        "x" * 41,
        "CON",
        "con",
        "COM1",
        "lpt9",
        "NUL",
    ),
)
def test_validate_study_id_rejects_unsafe_names(study_id: str) -> None:
    with pytest.raises(StudyIdError):
        validate_study_id(study_id)


def test_scan_folder_is_top_level_case_insensitive_and_lists_invalid(
    tmp_path: Path,
) -> None:
    valid_lower = tmp_path / "one.edf"
    valid_upper = tmp_path / "TWO.EDF"
    invalid = tmp_path / "broken.eDf"
    make_synthetic_edf(valid_lower)
    make_synthetic_edf(valid_upper)
    invalid.write_bytes(b"not an EDF")
    nested = tmp_path / "nested"
    nested.mkdir()
    make_synthetic_edf(nested / "hidden.edf")
    (tmp_path / "ignore.txt").write_text("not selected", encoding="utf-8")

    entries = scan_folder(tmp_path)

    assert {entry.path.name for entry in entries} == {
        "one.edf",
        "TWO.EDF",
        "broken.eDf",
    }
    by_name = {entry.path.name: entry for entry in entries}
    assert by_name["one.edf"].is_valid
    assert by_name["TWO.EDF"].is_valid
    assert not by_name["broken.eDf"].is_valid
    assert isinstance(by_name["broken.eDf"].error, EdfValidationError)


def test_scan_folder_rejects_edf_symlink(tmp_path: Path) -> None:
    source = tmp_path / "source.bin"
    make_synthetic_edf(source)
    link = tmp_path / "linked.edf"
    try:
        link.symlink_to(source)
    except OSError:
        pytest.skip("Creating symlinks is unavailable on this platform")

    [entry] = scan_folder(tmp_path)

    assert not entry.is_valid
    assert "Symbolic links" in entry.error.message


def test_inspect_rejects_bad_local_recording_id_unknown_records_and_geometry(
    tmp_path: Path,
) -> None:
    bad_recording_id = tmp_path / "bad-local.edf"
    make_synthetic_edf(
        bad_recording_id,
        local_recording_id="Device 25-FEB-2026 AUTO123 X DEVICE_01",
    )
    with pytest.raises(EdfValidationError, match="Startdate"):
        inspect_edf(bad_recording_id)

    open_recording = tmp_path / "open.edf"
    make_synthetic_edf(open_recording, records_field=-1)
    with pytest.raises(EdfValidationError, match=r"\(-1\)"):
        inspect_edf(open_recording)

    truncated = tmp_path / "truncated.edf"
    make_synthetic_edf(truncated)
    truncated.write_bytes(truncated.read_bytes()[:-1])
    with pytest.raises(EdfValidationError, match="geometry"):
        inspect_edf(truncated)


def test_preflight_builds_exact_padded_patient_field(tmp_path: Path) -> None:
    source = tmp_path / "SYNTHETIC_PERSON.edf"
    make_synthetic_edf(source)

    plan = preflight_batch([DeidentificationJob(source, "sas_023")])
    [prepared] = plan.jobs

    expected = b"AUTO85061915252301 X 01-JAN-1999 sas_023"
    assert prepared.patient_field == expected.ljust(80, b" ")
    assert len(prepared.patient_field) == 80
    assert prepared.target_path == tmp_path / "sas_023.edf"
    assert plan.required_free_bytes == source.stat().st_size


def test_preflight_rejects_patient_field_overflow(tmp_path: Path) -> None:
    source = tmp_path / "source.edf"
    make_synthetic_edf(
        source,
        local_recording_id=f"Startdate 25-FEB-2026 {'A' * 40} X DEVICE",
    )

    with pytest.raises(BatchPreflightError, match="80-byte"):
        preflight_batch([DeidentificationJob(source, "S" * 40)])


def test_preflight_aggregates_duplicate_and_existing_filename_conflicts(
    tmp_path: Path,
) -> None:
    first = tmp_path / "first.edf"
    second = tmp_path / "second.edf"
    make_synthetic_edf(first)
    make_synthetic_edf(second)

    with pytest.raises(BatchPreflightError, match="another selected row"):
        preflight_batch(
            [
                DeidentificationJob(first, "Study_1"),
                DeidentificationJob(second, "study_1"),
            ]
        )

    existing = tmp_path / "TAKEN.EDF"
    make_synthetic_edf(existing)
    with pytest.raises(BatchPreflightError, match="already exists"):
        preflight_batch([DeidentificationJob(first, "taken")])


def test_preflight_treats_a_different_hard_link_as_an_existing_target(
    tmp_path: Path,
) -> None:
    source = tmp_path / "source.edf"
    make_synthetic_edf(source)
    target = tmp_path / "study_1.edf"
    try:
        os.link(source, target)
    except OSError:
        pytest.skip("Hard links are unavailable on this filesystem")

    with pytest.raises(BatchPreflightError, match="already exists"):
        preflight_batch([DeidentificationJob(source, "study_1")])


def test_preflight_blocks_when_safe_copy_will_not_fit(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    source = tmp_path / "source.edf"
    make_synthetic_edf(source)
    monkeypatch.setattr(
        core.shutil,
        "disk_usage",
        lambda _folder: SimpleNamespace(free=source.stat().st_size - 1),
    )

    with pytest.raises(BatchPreflightError, match="enough free space"):
        preflight_batch([DeidentificationJob(source, "study_1")])


def test_preflight_blocks_unresolved_recovery_file(tmp_path: Path) -> None:
    source = tmp_path / "source.edf"
    make_synthetic_edf(source)
    recovery = tmp_path / f"{core.RECOVERY_PREFIX}orphan{core.TEMP_SUFFIX}"
    recovery.write_bytes(b"unresolved recovery data")

    with pytest.raises(BatchPreflightError, match="unresolved recovery file"):
        preflight_batch([DeidentificationJob(source, "study_1")])


def test_deidentify_preserves_every_other_byte_permissions_and_mtime(
    tmp_path: Path,
) -> None:
    source = tmp_path / "SYNTHETIC_PERSON.edf"
    original = make_synthetic_edf(source)
    os.chmod(source, 0o640)
    os.utime(source, ns=(1_700_000_000_000_000_000,) * 2)
    original_stat = source.stat()
    [prepared] = preflight_batch(
        [DeidentificationJob(source, "sas_023")]
    ).jobs

    progress: list[tuple[str, int, int]] = []
    result = deidentify_file(
        prepared,
        progress=lambda stage, completed, total: progress.append(
            (stage, completed, total)
        ),
    )

    target = tmp_path / "sas_023.edf"
    deidentified = target.read_bytes()
    assert result.status == "completed"
    assert result.target_path == target
    assert not source.exists()
    assert deidentified[8:88] == (
        b"AUTO85061915252301 X 01-JAN-1999 sas_023".ljust(80, b" ")
    )
    assert deidentified[:8] + deidentified[88:] == original[:8] + original[88:]
    assert len(deidentified) == len(original)
    assert target.stat().st_mtime_ns == original_stat.st_mtime_ns
    if os.name != "nt":
        assert stat.S_IMODE(target.stat().st_mode) == 0o640
    assert {item[0] for item in progress} == {
        "copy",
        "verify",
        "commit",
        "rename",
    }
    assert _temp_files(tmp_path) == []


def test_cancellation_before_commit_leaves_source_byte_for_byte_unchanged(
    tmp_path: Path,
) -> None:
    source = tmp_path / "SYNTHETIC_PERSON.edf"
    original = make_synthetic_edf(source)
    [prepared] = preflight_batch(
        [DeidentificationJob(source, "sas_023")]
    ).jobs
    checks = 0

    def cancel() -> bool:
        nonlocal checks
        checks += 1
        return checks >= 2

    with pytest.raises(CancellationError) as error:
        deidentify_file(prepared, cancel=cancel)

    assert source.read_bytes() == original
    assert not (tmp_path / "sas_023.edf").exists()
    assert error.value.temp_cleanup == "removed"
    assert _temp_files(tmp_path) == []


def test_readback_hash_detects_changed_nonpatient_byte_and_cleans_temp(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    source = tmp_path / "SYNTHETIC_PERSON.edf"
    original = make_synthetic_edf(source)
    [prepared] = preflight_batch(
        [DeidentificationJob(source, "sas_023")]
    ).jobs
    real_verify = core._verify_temporary_copy

    def corrupt_then_verify(temp_path: Path, **kwargs: object) -> None:
        with temp_path.open("r+b") as file_object:
            file_object.seek(300)
            original_byte = file_object.read(1)
            file_object.seek(300)
            file_object.write(bytes([original_byte[0] ^ 0x01]))
            file_object.flush()
            os.fsync(file_object.fileno())
        real_verify(temp_path, **kwargs)

    monkeypatch.setattr(core, "_verify_temporary_copy", corrupt_then_verify)
    with pytest.raises(DeidentificationError, match="outside the patient field"):
        deidentify_file(prepared)

    assert source.read_bytes() == original
    assert _temp_files(tmp_path) == []


def test_source_modification_during_copy_is_never_overwritten(
    tmp_path: Path,
) -> None:
    source = tmp_path / "SYNTHETIC_PERSON.edf"
    make_synthetic_edf(source)
    [prepared] = preflight_batch(
        [DeidentificationJob(source, "sas_023")]
    ).jobs
    changed = False

    def modify_source(stage: str, _completed: int, _total: int) -> None:
        nonlocal changed
        if stage == "copy" and not changed:
            with source.open("ab") as file_object:
                file_object.write(b"external change")
                file_object.flush()
                os.fsync(file_object.fileno())
            changed = True

    with pytest.raises(DeidentificationError, match="changed"):
        deidentify_file(prepared, progress=modify_source)

    assert source.read_bytes().endswith(b"external change")
    assert source.read_bytes()[8:88] != prepared.patient_field
    assert _temp_files(tmp_path) == []


def test_open_failure_after_temp_creation_closes_fd_and_removes_temp(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    source = tmp_path / "SYNTHETIC_PERSON.edf"
    original = make_synthetic_edf(source)
    [prepared] = preflight_batch(
        [DeidentificationJob(source, "sas_023")]
    ).jobs
    real_open_source = core._open_source
    call_count = 0

    def fail_second_open(path: Path, *, stage: str):
        nonlocal call_count
        call_count += 1
        if call_count == 2:
            raise EdfValidationError(
                "Injected open failure",
                stage=stage,
                path=path,
            )
        return real_open_source(path, stage=stage)

    monkeypatch.setattr(core, "_open_source", fail_second_open)

    with pytest.raises(EdfValidationError, match="Injected open failure") as error:
        deidentify_file(prepared)

    assert error.value.temp_cleanup == "removed"
    assert source.read_bytes() == original
    assert _temp_files(tmp_path) == []


def test_target_appearing_after_preflight_is_not_overwritten(
    tmp_path: Path,
) -> None:
    source = tmp_path / "SYNTHETIC_PERSON.edf"
    original = make_synthetic_edf(source)
    [prepared] = preflight_batch(
        [DeidentificationJob(source, "sas_023")]
    ).jobs
    target_contents = b"unrelated existing file"
    created = False

    def create_target(stage: str, _completed: int, _total: int) -> None:
        nonlocal created
        if stage == "copy" and not created:
            prepared.target_path.write_bytes(target_contents)
            created = True

    with pytest.raises(DeidentificationError, match="appeared after preflight"):
        deidentify_file(prepared, progress=create_target)

    assert source.read_bytes() == original
    assert prepared.target_path.read_bytes() == target_contents
    assert _temp_files(tmp_path) == []


def test_target_race_at_install_is_not_overwritten(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    source = tmp_path / "SYNTHETIC_PERSON.edf"
    original = make_synthetic_edf(source)
    [prepared] = preflight_batch(
        [DeidentificationJob(source, "sas_023")]
    ).jobs
    target_contents = b"file created by another process"
    real_install = core._install_verified_output

    def create_target_then_install(*args: object, **kwargs: object) -> None:
        prepared.target_path.write_bytes(target_contents)
        real_install(*args, **kwargs)

    monkeypatch.setattr(
        core,
        "_install_verified_output",
        create_target_then_install,
    )

    with pytest.raises(DeidentificationError, match="could not be installed"):
        deidentify_file(prepared)

    assert prepared.target_path.read_bytes() == target_contents
    assert source.read_bytes() == original
    assert _temp_files(tmp_path) == []


def test_case_only_output_name_is_normalized_exactly(tmp_path: Path) -> None:
    source = tmp_path / "SAS_023.EDF"
    original = make_synthetic_edf(source)
    [prepared] = preflight_batch(
        [DeidentificationJob(source, "sas_023")]
    ).jobs

    result = deidentify_file(prepared)

    assert result.target_path.name == "sas_023.edf"
    assert os.listdir(tmp_path) == ["sas_023.edf"]
    deidentified = (tmp_path / "sas_023.edf").read_bytes()
    assert deidentified[8:88] == prepared.patient_field
    assert deidentified[:8] + deidentified[88:] == original[:8] + original[88:]


def test_case_only_install_failure_restores_original(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    source = tmp_path / "SAS_023.EDF"
    original = make_synthetic_edf(source)
    [prepared] = preflight_batch(
        [DeidentificationJob(source, "sas_023")]
    ).jobs

    def fail_install(*_args: object, **_kwargs: object) -> None:
        raise DeidentificationError(
            "Injected install failure.",
            stage="commit",
            path=prepared.target_path,
        )

    monkeypatch.setattr(core, "_install_verified_output", fail_install)

    with pytest.raises(DeidentificationError, match="restored"):
        deidentify_file(prepared)

    assert source.read_bytes() == original
    assert os.listdir(tmp_path) == ["SAS_023.EDF"]
    assert _temp_files(tmp_path) == []


def test_verify_progress_mutation_is_detected_before_commit(
    tmp_path: Path,
) -> None:
    source = tmp_path / "SYNTHETIC_PERSON.edf"
    original = make_synthetic_edf(source)
    [prepared] = preflight_batch(
        [DeidentificationJob(source, "sas_023")]
    ).jobs
    corrupted = False

    def corrupt_temp(stage: str, _completed: int, _total: int) -> None:
        nonlocal corrupted
        if stage != "verify" or corrupted:
            return
        [temporary] = _temp_files(tmp_path)
        with temporary.open("r+b") as file_object:
            file_object.seek(0)
            original_byte = file_object.read(1)
            file_object.seek(0)
            file_object.write(bytes([original_byte[0] ^ 0x01]))
            file_object.flush()
            os.fsync(file_object.fileno())
        corrupted = True

    with pytest.raises(DeidentificationError, match="outside the patient field"):
        deidentify_file(prepared, progress=corrupt_temp)

    assert corrupted
    assert source.read_bytes() == original
    assert not prepared.target_path.exists()
    assert _temp_files(tmp_path) == []


def test_source_replacement_after_output_install_is_preserved_and_reported(
    tmp_path: Path,
) -> None:
    source = tmp_path / "SYNTHETIC_PERSON.edf"
    original = make_synthetic_edf(source)
    [prepared] = preflight_batch(
        [DeidentificationJob(source, "sas_023")]
    ).jobs
    replacement = b"concurrent replacement"

    def replace_source(stage: str, _completed: int, _total: int) -> None:
        if stage == "commit":
            source.write_bytes(replacement)

    with pytest.raises(DeidentificationError, match="source EDF changed"):
        deidentify_file(prepared, progress=replace_source)

    assert source.read_bytes() == replacement
    output = prepared.target_path.read_bytes()
    assert output[8:88] == prepared.patient_field
    assert output[:8] + output[88:] == original[:8] + original[88:]
    assert _temp_files(tmp_path) == []


def test_output_mutation_during_source_quarantine_is_caught_before_removal(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    source = tmp_path / "SYNTHETIC_PERSON.edf"
    original = make_synthetic_edf(source)
    [prepared] = preflight_batch(
        [DeidentificationJob(source, "sas_023")]
    ).jobs
    real_quarantine = core._quarantine_expected_source

    def quarantine_then_corrupt(*args: object, **kwargs: object) -> Path:
        quarantine = real_quarantine(*args, **kwargs)
        with prepared.target_path.open("r+b") as file_object:
            file_object.seek(0)
            original_byte = file_object.read(1)
            file_object.seek(0)
            file_object.write(bytes([original_byte[0] ^ 0x01]))
            file_object.flush()
            os.fsync(file_object.fileno())
        return quarantine

    monkeypatch.setattr(
        core,
        "_quarantine_expected_source",
        quarantine_then_corrupt,
    )

    with pytest.raises(DeidentificationError, match="final verification failed"):
        deidentify_file(prepared)

    assert source.read_bytes() == original
    assert prepared.target_path.read_bytes()[0:1] != original[0:1]
    assert _temp_files(tmp_path) == []


def test_final_progress_mutations_are_checked_before_success(
    tmp_path: Path,
) -> None:
    source = tmp_path / "SYNTHETIC_PERSON.edf"
    make_synthetic_edf(source)
    [prepared] = preflight_batch(
        [DeidentificationJob(source, "sas_023")]
    ).jobs
    replacement = b"concurrent PHI-name entry"
    corruption = b"corrupted during rename progress"

    def mutate_paths(stage: str, _completed: int, _total: int) -> None:
        if stage == "rename":
            prepared.target_path.write_bytes(corruption)
            source.write_bytes(replacement)

    with pytest.raises(DeidentificationError):
        deidentify_file(prepared, progress=mutate_paths)

    assert source.read_bytes() == replacement
    assert prepared.target_path.read_bytes() == corruption


def test_last_source_guard_race_never_deletes_replacement(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    source = tmp_path / "SYNTHETIC_PERSON.edf"
    make_synthetic_edf(source)
    [prepared] = preflight_batch(
        [DeidentificationJob(source, "sas_023")]
    ).jobs
    replacement = b"replacement after final source check"
    real_ensure = core._ensure_source_unchanged
    replaced = False

    def replace_after_guard(job: object, *, stage: str) -> None:
        nonlocal replaced
        real_ensure(job, stage=stage)
        if stage == "commit" and not replaced:
            source.write_bytes(replacement)
            replaced = True

    monkeypatch.setattr(core, "_ensure_source_unchanged", replace_after_guard)

    with pytest.raises(DeidentificationError, match="source EDF changed"):
        deidentify_file(prepared)

    assert source.read_bytes() == replacement
    assert prepared.target_path.exists()
    assert _temp_files(tmp_path) == []


def test_missing_exclusive_rename_support_fails_before_source_changes(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    source = tmp_path / "SYNTHETIC_PERSON.edf"
    original = make_synthetic_edf(source)
    [prepared] = preflight_batch(
        [DeidentificationJob(source, "sas_023")]
    ).jobs

    monkeypatch.setattr(
        core,
        "_native_rename_noreplace",
        lambda _source, _target: False,
    )

    with pytest.raises(DeidentificationError, match="could not be installed"):
        deidentify_file(prepared)

    assert source.read_bytes() == original
    assert not prepared.target_path.exists()
    assert _temp_files(tmp_path) == []


def test_installed_output_verification_failure_keeps_original(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    source = tmp_path / "SYNTHETIC_PERSON.edf"
    original = make_synthetic_edf(source)
    [prepared] = preflight_batch(
        [DeidentificationJob(source, "sas_023")]
    ).jobs
    real_verify = core._verify_temporary_copy
    verify_calls = 0

    def corrupt_installed_output(path: Path, **kwargs: object) -> None:
        nonlocal verify_calls
        verify_calls += 1
        if verify_calls == 2:
            path.write_bytes(b"corrupted installed output")
        real_verify(path, **kwargs)

    monkeypatch.setattr(
        core,
        "_verify_temporary_copy",
        corrupt_installed_output,
    )

    with pytest.raises(
        DeidentificationError,
        match="final verification failed",
    ):
        deidentify_file(prepared)

    assert source.read_bytes() == original
    assert prepared.target_path.read_bytes() == b"corrupted installed output"
    assert _temp_files(tmp_path) == []


def test_quarantine_identity_failure_preserves_concurrent_source_and_original(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    source = tmp_path / "SYNTHETIC_PERSON.edf"
    original = make_synthetic_edf(source)
    [prepared] = preflight_batch(
        [DeidentificationJob(source, "sas_023")]
    ).jobs
    concurrent_source = b"concurrent source entry"

    def fail_identity_verification(
        _path: Path,
        **_kwargs: object,
    ) -> None:
        source.write_bytes(concurrent_source)
        raise DeidentificationError(
            "Injected quarantine identity failure.",
            stage="rename",
            path=source,
        )

    monkeypatch.setattr(core, "_verify_full_file", fail_identity_verification)

    with pytest.raises(DeidentificationError, match="retained at the recovery"):
        deidentify_file(prepared)

    assert source.read_bytes() == concurrent_source
    [recovery] = _temp_files(tmp_path)
    assert recovery.read_bytes() == original
    assert prepared.target_path.exists()


def test_quarantine_deletion_failure_retains_verified_output_and_original(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    source = tmp_path / "SYNTHETIC_PERSON.edf"
    original = make_synthetic_edf(source)
    [prepared] = preflight_batch(
        [DeidentificationJob(source, "sas_023")]
    ).jobs
    real_unlink = Path.unlink

    def reject_quarantine_unlink(
        path: Path,
        *args: object,
        **kwargs: object,
    ) -> None:
        if path.name.startswith(f"{core.TEMP_PREFIX}rename-"):
            raise OSError(errno.EACCES, "injected quarantine deletion failure")
        real_unlink(path, *args, **kwargs)

    monkeypatch.setattr(Path, "unlink", reject_quarantine_unlink)

    with pytest.raises(DeidentificationError, match="original could not be removed"):
        deidentify_file(prepared)

    [recovery] = _temp_files(tmp_path)
    assert recovery.read_bytes() == original
    assert prepared.target_path.exists()


def test_output_mutation_after_verification_cannot_leave_silent_data_loss(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    source = tmp_path / "SYNTHETIC_PERSON.edf"
    make_synthetic_edf(source)
    [prepared] = preflight_batch(
        [DeidentificationJob(source, "sas_023")]
    ).jobs
    real_quarantine = core._quarantine_expected_source
    corrupted = b"corrupted after installed-output verification"

    def quarantine_then_corrupt(
        job: object,
        *,
        expected_digest: bytes,
    ) -> tuple[Path, object]:
        quarantine = real_quarantine(
            job,
            expected_digest=expected_digest,
        )
        prepared.target_path.write_bytes(corrupted)
        return quarantine

    monkeypatch.setattr(
        core,
        "_quarantine_expected_source",
        quarantine_then_corrupt,
    )

    with pytest.raises(DeidentificationError, match="final verification failed"):
        deidentify_file(prepared)

    assert prepared.target_path.read_bytes() == corrupted
    assert source.exists()
    assert _temp_files(tmp_path) == []


def test_source_reappearance_during_quarantine_deletion_is_not_silent(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    source = tmp_path / "SYNTHETIC_PERSON.edf"
    make_synthetic_edf(source)
    [prepared] = preflight_batch(
        [DeidentificationJob(source, "sas_023")]
    ).jobs
    real_remove = core._remove_quarantined_original
    concurrent_source = b"source reappeared during deletion"

    def remove_then_reappear(
        quarantine: Path,
        *,
        expected_signature: object,
        expected_output_signature: object,
        output_path: Path,
        original_path: Path,
    ) -> None:
        real_remove(
            quarantine,
            expected_signature=expected_signature,
            expected_output_signature=expected_output_signature,
            output_path=output_path,
            original_path=original_path,
        )
        original_path.write_bytes(concurrent_source)

    monkeypatch.setattr(
        core,
        "_remove_quarantined_original",
        remove_then_reappear,
    )

    with pytest.raises(DeidentificationError, match="another entry appeared"):
        deidentify_file(prepared)

    assert source.read_bytes() == concurrent_source
    assert prepared.target_path.exists()


def test_quarantine_replacement_is_not_deleted_as_the_original(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    source = tmp_path / "SYNTHETIC_PERSON.edf"
    original = make_synthetic_edf(source)
    [prepared] = preflight_batch(
        [DeidentificationJob(source, "sas_023")]
    ).jobs
    real_remove = core._remove_quarantined_original
    moved_original = tmp_path / "externally-moved-original.bin"
    unrelated = b"unrelated replacement at quarantine path"

    def replace_quarantine_then_remove(
        quarantine: Path,
        *,
        expected_signature: object,
        expected_output_signature: object,
        output_path: Path,
        original_path: Path,
    ) -> None:
        quarantine.rename(moved_original)
        quarantine.write_bytes(unrelated)
        real_remove(
            quarantine,
            expected_signature=expected_signature,
            expected_output_signature=expected_output_signature,
            output_path=output_path,
            original_path=original_path,
        )

    monkeypatch.setattr(
        core,
        "_remove_quarantined_original",
        replace_quarantine_then_remove,
    )

    with pytest.raises(DeidentificationError, match="recovery entry changed"):
        deidentify_file(prepared)

    assert moved_original.read_bytes() == original
    assert any(path.read_bytes() == unrelated for path in tmp_path.iterdir())
    assert prepared.target_path.exists()


def test_output_mutation_after_final_verifier_return_is_not_silent(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    source = tmp_path / "SYNTHETIC_PERSON.edf"
    make_synthetic_edf(source)
    [prepared] = preflight_batch(
        [DeidentificationJob(source, "sas_023")]
    ).jobs
    real_verify = core._verify_temporary_copy
    verify_calls = 0
    corrupted = b"corrupted immediately after final verification"

    def verify_then_corrupt(path: Path, **kwargs: object) -> object:
        nonlocal verify_calls
        verify_calls += 1
        verified_signature = real_verify(path, **kwargs)
        if verify_calls == 2:
            path.write_bytes(corrupted)
        return verified_signature

    monkeypatch.setattr(core, "_verify_temporary_copy", verify_then_corrupt)

    with pytest.raises(DeidentificationError, match="output changed"):
        deidentify_file(prepared)

    assert prepared.target_path.read_bytes() == corrupted
    assert source.exists()


def test_terminal_progress_cannot_corrupt_the_only_remaining_output(
    tmp_path: Path,
) -> None:
    source = tmp_path / "SYNTHETIC_PERSON.edf"
    original = make_synthetic_edf(source)
    [prepared] = preflight_batch(
        [DeidentificationJob(source, "sas_023")]
    ).jobs
    corrupted = b"corrupted by terminal progress callback"

    def corrupt_on_terminal_progress(
        stage: str,
        _completed: int,
        _total: int,
    ) -> None:
        if stage == "rename":
            prepared.target_path.write_bytes(corrupted)

    with pytest.raises(
        DeidentificationError,
        match="final verification failed",
    ):
        deidentify_file(prepared, progress=corrupt_on_terminal_progress)

    assert source.read_bytes() == original
    assert prepared.target_path.read_bytes() == corrupted


def test_terminal_progress_source_reappearance_is_not_silent(tmp_path: Path) -> None:
    source = tmp_path / "SYNTHETIC_PERSON.edf"
    make_synthetic_edf(source)
    [prepared] = preflight_batch(
        [DeidentificationJob(source, "sas_023")]
    ).jobs
    concurrent_source = b"source recreated by terminal progress callback"

    def recreate_source_on_terminal_progress(
        stage: str,
        _completed: int,
        _total: int,
    ) -> None:
        if stage == "rename":
            source.write_bytes(concurrent_source)

    with pytest.raises(DeidentificationError, match="could not be removed safely"):
        deidentify_file(prepared, progress=recreate_source_on_terminal_progress)

    assert source.read_bytes() == concurrent_source
    assert prepared.target_path.exists()


def test_process_batch_keeps_completed_then_marks_failure_and_untouched(
    tmp_path: Path,
) -> None:
    sources = [tmp_path / f"source-{index}.edf" for index in range(3)]
    for source in sources:
        make_synthetic_edf(source)
    plan = preflight_batch(
        [
            DeidentificationJob(source, f"study_{index}")
            for index, source in enumerate(sources)
        ]
    )
    sources[1].unlink()

    result = process_batch(plan)

    assert [item.status for item in result.results] == [
        "completed",
        "failed",
        "untouched",
    ]
    assert result.stopped_early
    assert result.completed_count == 1
    assert result.failed_count == 1
    assert result.untouched_count == 1
    assert (tmp_path / "study_0.edf").exists()
    assert sources[2].exists()
