from __future__ import annotations

import os
from pathlib import Path
from types import SimpleNamespace

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

import pytest
from PySide6.QtCore import Qt
from PySide6.QtWidgets import QApplication

from edf_deidentifier import gui


@pytest.fixture(scope="module")
def app() -> QApplication:
    application = QApplication.instance() or QApplication([])
    return application


def _scan_entry(path: Path, *, valid: bool, error: object = None) -> object:
    return SimpleNamespace(path=path, is_valid=valid, error=error)


def test_main_window_uses_the_agreed_table_columns(app: QApplication) -> None:
    window = gui.MainWindow()
    headers = [
        window._table.horizontalHeaderItem(column).text()
        for column in range(window._table.columnCount())
    ]

    assert headers == ["Process", "Original filename", "Study ID", "Status"]
    window.close()


def test_valid_rows_default_checked_and_invalid_rows_are_disabled(
    app: QApplication,
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    valid_path = tmp_path / "CLINICAL_NAME.edf"
    invalid_path = tmp_path / "broken.EDF"
    valid_path.touch()
    invalid_path.touch()
    monkeypatch.setattr(
        gui,
        "scan_folder",
        lambda _folder: (
            _scan_entry(valid_path, valid=True),
            _scan_entry(
                invalid_path,
                valid=False,
                error=SimpleNamespace(message="The fixed header is truncated."),
            ),
        ),
    )
    window = gui.MainWindow()

    window._load_folder(tmp_path)

    valid_process = window._table.item(0, window.PROCESS_COLUMN)
    invalid_process = window._table.item(1, window.PROCESS_COLUMN)
    invalid_study_id = window._table.item(1, window.STUDY_ID_COLUMN)
    assert valid_process.checkState() == Qt.CheckState.Checked
    assert valid_process.flags() & Qt.ItemFlag.ItemIsUserCheckable
    assert invalid_process.flags() == Qt.ItemFlag.NoItemFlags
    assert invalid_study_id.flags() == Qt.ItemFlag.NoItemFlags
    assert "truncated" in window._table.item(1, window.STATUS_COLUMN).text()
    window.close()


def test_duplicate_checked_study_ids_block_confirmation(
    app: QApplication,
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    first_path = tmp_path / "FIRST_PATIENT.edf"
    second_path = tmp_path / "SECOND_PATIENT.edf"
    first_path.touch()
    second_path.touch()
    monkeypatch.setattr(
        gui,
        "scan_folder",
        lambda _folder: (
            _scan_entry(first_path, valid=True),
            _scan_entry(second_path, valid=True),
        ),
    )
    window = gui.MainWindow()
    window._load_folder(tmp_path)

    window._table.item(0, window.STUDY_ID_COLUMN).setText("sas_023")
    window._table.item(1, window.STUDY_ID_COLUMN).setText("sas_023")
    app.processEvents()

    assert not window._confirm_button.isEnabled()
    assert "Duplicate" in window._table.item(0, window.STATUS_COLUMN).text()
    assert "Duplicate" in window._table.item(1, window.STATUS_COLUMN).text()

    window._table.item(1, window.PROCESS_COLUMN).setCheckState(
        Qt.CheckState.Unchecked
    )
    app.processEvents()

    assert window._confirm_button.isEnabled()
    assert window._table.item(0, window.STATUS_COLUMN).text() == "Ready"
    assert window._table.item(1, window.STATUS_COLUMN).text() == "Not selected"

    window._table.item(0, window.STUDY_ID_COLUMN).setText(" sas_023 ")
    app.processEvents()
    assert not window._confirm_button.isEnabled()

    window.close()
