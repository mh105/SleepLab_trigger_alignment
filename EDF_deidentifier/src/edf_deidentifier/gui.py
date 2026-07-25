"""PySide6 desktop interface for the EDF deidentifier."""

from __future__ import annotations

import re
import sys
import threading
from dataclasses import dataclass
from pathlib import Path
from typing import Sequence

from PySide6.QtCore import QObject, QThread, QTimer, Qt, Signal, Slot
from PySide6.QtGui import QColor, QCloseEvent
from PySide6.QtWidgets import (
    QAbstractItemView,
    QApplication,
    QDialog,
    QDialogButtonBox,
    QFileDialog,
    QHBoxLayout,
    QHeaderView,
    QLabel,
    QMainWindow,
    QMessageBox,
    QProgressBar,
    QPushButton,
    QTableWidget,
    QTableWidgetItem,
    QVBoxLayout,
    QWidget,
)

from .core import (
    CancellationError,
    DeidentificationJob,
    EdfError,
    deidentify_file,
    preflight_batch,
    scan_folder,
    validate_study_id,
)


_WHITESPACE = re.compile(r"\s+")


def _message(value: object, *, limit: int | None = None) -> str:
    """Return a readable one-line error without exposing object repr details."""

    text = getattr(value, "message", None) or str(value) or type(value).__name__
    text = _WHITESPACE.sub(" ", text).strip()
    if limit is not None and len(text) > limit:
        return f"{text[: limit - 1]}…"
    return text


def _stage(value: object, default: str = "unknown") -> str:
    stage = getattr(value, "stage", None)
    return str(stage) if stage else default


def _cleanup(value: object, default: str) -> str:
    cleanup = getattr(value, "temp_cleanup", None)
    if cleanup is None:
        return default
    if cleanup is True:
        return "Temporary file removed"
    if cleanup is False:
        return "Temporary-file cleanup failed"
    return _message(cleanup)


def _stage_label(stage: str) -> str:
    return {
        "copy": "Copying",
        "verify": "Verifying",
        "commit": "Committing",
        "rename": "Renaming",
        "preflight": "Preflight",
    }.get(stage, stage.replace("_", " ").capitalize())


@dataclass(frozen=True)
class _Row:
    path: Path
    valid_edf: bool


@dataclass(frozen=True)
class _Outcome:
    row: int
    original_filename: str
    target_filename: str
    result: str
    stage: str
    error: str
    cleanup: str


class _BatchWorker(QObject):
    file_started = Signal(int, str, int, int)
    progress_changed = Signal(int, str, object, object)
    outcome_ready = Signal(object)
    finished = Signal(object, bool, bool)

    def __init__(
        self,
        prepared_rows: Sequence[tuple[int, object, str, str]],
    ) -> None:
        super().__init__()
        self._prepared_rows = tuple(prepared_rows)
        self._stop = threading.Event()

    def request_stop(self) -> None:
        self._stop.set()

    def _untouched(
        self,
        row: int,
        original: str,
        target: str,
        reason: str,
        *,
        stage: str = "not started",
        cleanup: str = "Not needed",
    ) -> _Outcome:
        return _Outcome(
            row=row,
            original_filename=original,
            target_filename=target,
            result="untouched",
            stage=stage,
            error=reason,
            cleanup=cleanup,
        )

    @Slot()
    def run(self) -> None:
        outcomes: list[_Outcome] = []
        stopped = False
        failed = False
        total_files = len(self._prepared_rows)

        for index, (row, prepared, original, target) in enumerate(
            self._prepared_rows
        ):
            if self._stop.is_set():
                stopped = True
                for rest_row, _, rest_original, rest_target in self._prepared_rows[
                    index:
                ]:
                    outcome = self._untouched(
                        rest_row,
                        rest_original,
                        rest_target,
                        "Stopped before processing",
                    )
                    outcomes.append(outcome)
                    self.outcome_ready.emit(outcome)
                break

            self.file_started.emit(row, original, index + 1, total_files)

            def progress(
                stage: str,
                completed: int,
                total: int,
                current_row: int = row,
            ) -> None:
                self.progress_changed.emit(
                    current_row, stage, completed, total
                )

            try:
                file_result = deidentify_file(
                    prepared,
                    cancel=self._stop,
                    progress=progress,
                )
            except CancellationError as exc:
                stopped = True
                outcome = self._untouched(
                    row,
                    original,
                    target,
                    _message(exc),
                    stage=_stage(exc),
                    cleanup=_cleanup(exc, "Unknown"),
                )
                outcomes.append(outcome)
                self.outcome_ready.emit(outcome)
                for (
                    rest_row,
                    _,
                    rest_original,
                    rest_target,
                ) in self._prepared_rows[index + 1 :]:
                    rest = self._untouched(
                        rest_row,
                        rest_original,
                        rest_target,
                        "Stopped before processing",
                    )
                    outcomes.append(rest)
                    self.outcome_ready.emit(rest)
                break
            except EdfError as exc:
                failed = True
                outcome = _Outcome(
                    row=row,
                    original_filename=original,
                    target_filename=target,
                    result="failed",
                    stage=_stage(exc),
                    error=_message(exc),
                    cleanup=_cleanup(exc, "Unknown"),
                )
                outcomes.append(outcome)
                self.outcome_ready.emit(outcome)
                for (
                    rest_row,
                    _,
                    rest_original,
                    rest_target,
                ) in self._prepared_rows[index + 1 :]:
                    rest = self._untouched(
                        rest_row,
                        rest_original,
                        rest_target,
                        "Not started because an earlier file failed",
                    )
                    outcomes.append(rest)
                    self.outcome_ready.emit(rest)
                break
            except Exception as exc:  # pragma: no cover - defensive UI boundary
                failed = True
                outcome = _Outcome(
                    row=row,
                    original_filename=original,
                    target_filename=target,
                    result="failed",
                    stage="unknown",
                    error=_message(exc),
                    cleanup="Unknown",
                )
                outcomes.append(outcome)
                self.outcome_ready.emit(outcome)
                for (
                    rest_row,
                    _,
                    rest_original,
                    rest_target,
                ) in self._prepared_rows[index + 1 :]:
                    rest = self._untouched(
                        rest_row,
                        rest_original,
                        rest_target,
                        "Not started because an earlier file failed",
                    )
                    outcomes.append(rest)
                    self.outcome_ready.emit(rest)
                break
            else:
                outcome = _Outcome(
                    row=row,
                    original_filename=original,
                    target_filename=target,
                    result="completed",
                    stage="rename",
                    error="",
                    cleanup=_cleanup(file_result, "Temporary file removed"),
                )
                outcomes.append(outcome)
                self.outcome_ready.emit(outcome)

        self.finished.emit(tuple(outcomes), stopped, failed)


class _ResultsDialog(QDialog):
    def __init__(self, outcomes: Sequence[_Outcome], parent: QWidget) -> None:
        super().__init__(parent)
        self.setWindowTitle("Deidentification results")
        self.resize(1000, 440)

        completed = sum(item.result == "completed" for item in outcomes)
        failed = sum(item.result == "failed" for item in outcomes)
        untouched = sum(item.result == "untouched" for item in outcomes)

        layout = QVBoxLayout(self)
        summary = QLabel(
            f"Completed: {completed}    Failed: {failed}    "
            f"Untouched: {untouched}"
        )
        layout.addWidget(summary)

        table = QTableWidget(len(outcomes), 5, self)
        table.setHorizontalHeaderLabels(
            [
                "Original filename",
                "Result",
                "Failed/stopped stage",
                "Error or explanation",
                "Temporary-file cleanup",
            ]
        )
        table.setEditTriggers(QAbstractItemView.EditTrigger.NoEditTriggers)
        table.setSelectionMode(QAbstractItemView.SelectionMode.NoSelection)
        table.setWordWrap(True)
        table.verticalHeader().setVisible(False)
        table.setAlternatingRowColors(True)

        for row, outcome in enumerate(outcomes):
            result = outcome.result.capitalize()
            if outcome.result == "completed":
                result = f"Completed as {outcome.target_filename}"
            values = (
                outcome.original_filename,
                result,
                (
                    ""
                    if outcome.result == "completed"
                    else _stage_label(outcome.stage)
                ),
                outcome.error,
                outcome.cleanup,
            )
            for column, value in enumerate(values):
                table.setItem(row, column, QTableWidgetItem(value))

        header = table.horizontalHeader()
        header.setSectionResizeMode(0, QHeaderView.ResizeMode.ResizeToContents)
        header.setSectionResizeMode(1, QHeaderView.ResizeMode.ResizeToContents)
        header.setSectionResizeMode(2, QHeaderView.ResizeMode.ResizeToContents)
        header.setSectionResizeMode(3, QHeaderView.ResizeMode.Stretch)
        header.setSectionResizeMode(4, QHeaderView.ResizeMode.Stretch)
        table.resizeRowsToContents()
        layout.addWidget(table)

        buttons = QDialogButtonBox(QDialogButtonBox.StandardButton.Close)
        buttons.rejected.connect(self.reject)
        layout.addWidget(buttons)


class MainWindow(QMainWindow):
    PROCESS_COLUMN = 0
    FILENAME_COLUMN = 1
    STUDY_ID_COLUMN = 2
    STATUS_COLUMN = 3

    def __init__(self) -> None:
        super().__init__()
        self.setWindowTitle("EDF Deidentifier")
        self.resize(1000, 650)

        self._folder: Path | None = None
        self._rows: list[_Row] = []
        self._existing_names: dict[str, tuple[Path, ...]] = {}
        self._refreshing = False
        self._busy = False
        self._run_locked = False
        self._close_after_batch = False
        self._thread: QThread | None = None
        self._worker: _BatchWorker | None = None
        self._pending_results: tuple[_Outcome, ...] = ()
        self._pending_stopped = False
        self._pending_failed = False
        self._finished_count = 0

        central = QWidget(self)
        layout = QVBoxLayout(central)

        explanation = QLabel(
            "Select a folder containing EDF files. Selected files will be "
            "deidentified and renamed in place; subfolders are not scanned."
        )
        explanation.setWordWrap(True)
        layout.addWidget(explanation)

        folder_layout = QHBoxLayout()
        self._folder_label = QLabel("No EDF folder selected")
        self._folder_label.setTextInteractionFlags(
            Qt.TextInteractionFlag.TextSelectableByMouse
        )
        folder_layout.addWidget(self._folder_label, 1)
        self._select_folder_button = QPushButton("Select EDF Folder…")
        self._select_folder_button.clicked.connect(self.choose_folder)
        folder_layout.addWidget(self._select_folder_button)
        layout.addLayout(folder_layout)

        selection_layout = QHBoxLayout()
        self._count_label = QLabel("No files loaded")
        selection_layout.addWidget(self._count_label)
        selection_layout.addStretch(1)
        self._check_all_button = QPushButton("Check all")
        self._check_all_button.clicked.connect(lambda: self._set_all_checked(True))
        self._uncheck_all_button = QPushButton("Uncheck all")
        self._uncheck_all_button.clicked.connect(
            lambda: self._set_all_checked(False)
        )
        selection_layout.addWidget(self._check_all_button)
        selection_layout.addWidget(self._uncheck_all_button)
        layout.addLayout(selection_layout)

        self._table = QTableWidget(0, 4, self)
        self._table.setHorizontalHeaderLabels(
            ["Process", "Original filename", "Study ID", "Status"]
        )
        self._table.setAlternatingRowColors(True)
        self._table.setSelectionBehavior(
            QAbstractItemView.SelectionBehavior.SelectItems
        )
        self._table.setEditTriggers(
            QAbstractItemView.EditTrigger.DoubleClicked
            | QAbstractItemView.EditTrigger.SelectedClicked
            | QAbstractItemView.EditTrigger.EditKeyPressed
        )
        self._table.verticalHeader().setVisible(False)
        self._table.itemChanged.connect(self._item_changed)
        table_header = self._table.horizontalHeader()
        table_header.setSectionResizeMode(
            self.PROCESS_COLUMN, QHeaderView.ResizeMode.ResizeToContents
        )
        table_header.setSectionResizeMode(
            self.FILENAME_COLUMN, QHeaderView.ResizeMode.Stretch
        )
        table_header.setSectionResizeMode(
            self.STUDY_ID_COLUMN, QHeaderView.ResizeMode.Stretch
        )
        table_header.setSectionResizeMode(
            self.STATUS_COLUMN, QHeaderView.ResizeMode.Stretch
        )
        layout.addWidget(self._table, 1)

        self._current_label = QLabel("No batch running")
        self._current_progress = QProgressBar()
        self._current_progress.setRange(0, 1000)
        self._current_progress.setValue(0)
        self._current_progress.setFormat("Current file: no batch")
        self._overall_progress = QProgressBar()
        self._overall_progress.setRange(0, 1)
        self._overall_progress.setValue(0)
        self._overall_progress.setFormat("Overall: no batch")
        layout.addWidget(self._current_label)
        layout.addWidget(self._current_progress)
        layout.addWidget(self._overall_progress)

        action_layout = QHBoxLayout()
        action_layout.addStretch(1)
        self._stop_button = QPushButton("Stop safely")
        self._stop_button.clicked.connect(self.request_stop)
        self._confirm_button = QPushButton("Deidentify selected files…")
        self._confirm_button.clicked.connect(self._confirm_batch)
        action_layout.addWidget(self._stop_button)
        action_layout.addWidget(self._confirm_button)
        layout.addLayout(action_layout)

        self.setCentralWidget(central)
        self._update_controls()

    @Slot()
    def choose_folder(self) -> None:
        if self._busy:
            return
        start = str(self._folder) if self._folder is not None else ""
        selected = QFileDialog.getExistingDirectory(
            self,
            "Select EDF folder",
            start,
            QFileDialog.Option.ShowDirsOnly,
        )
        if selected:
            self._load_folder(Path(selected))

    def _load_folder(self, folder: Path) -> None:
        try:
            entries = scan_folder(folder)
            all_entries = tuple(folder.iterdir())
        except (EdfError, OSError) as exc:
            QMessageBox.critical(
                self,
                "Cannot scan folder",
                f"The selected folder could not be scanned.\n\n{_message(exc)}",
            )
            return

        self._folder = folder
        self._folder_label.setText(str(folder))
        self._folder_label.setToolTip(str(folder))
        self._run_locked = False
        self._rows = []
        existing: dict[str, list[Path]] = {}
        for path in all_entries:
            existing.setdefault(path.name.casefold(), []).append(path)
        self._existing_names = {
            name: tuple(paths) for name, paths in existing.items()
        }

        self._refreshing = True
        self._table.setRowCount(0)
        self._table.setRowCount(len(entries))

        for row, entry in enumerate(entries):
            valid = bool(entry.is_valid)
            self._rows.append(_Row(path=entry.path, valid_edf=valid))

            process_item = QTableWidgetItem()
            process_item.setTextAlignment(Qt.AlignmentFlag.AlignCenter)
            if valid:
                process_item.setFlags(
                    Qt.ItemFlag.ItemIsEnabled
                    | Qt.ItemFlag.ItemIsSelectable
                    | Qt.ItemFlag.ItemIsUserCheckable
                )
                process_item.setCheckState(Qt.CheckState.Checked)
            else:
                process_item.setFlags(Qt.ItemFlag.NoItemFlags)
                process_item.setCheckState(Qt.CheckState.Unchecked)
            self._table.setItem(row, self.PROCESS_COLUMN, process_item)

            filename_item = QTableWidgetItem(entry.path.name)
            filename_item.setFlags(
                Qt.ItemFlag.ItemIsEnabled | Qt.ItemFlag.ItemIsSelectable
            )
            self._table.setItem(row, self.FILENAME_COLUMN, filename_item)

            study_item = QTableWidgetItem("")
            if valid:
                study_item.setFlags(
                    Qt.ItemFlag.ItemIsEnabled
                    | Qt.ItemFlag.ItemIsSelectable
                    | Qt.ItemFlag.ItemIsEditable
                )
            else:
                study_item.setFlags(Qt.ItemFlag.NoItemFlags)
            self._table.setItem(row, self.STUDY_ID_COLUMN, study_item)

            if valid:
                status_text = "Study ID required"
            else:
                status_text = f"Unsupported EDF: {_message(entry.error, limit=150)}"
            status_item = QTableWidgetItem(status_text)
            status_item.setFlags(
                Qt.ItemFlag.ItemIsEnabled | Qt.ItemFlag.ItemIsSelectable
            )
            status_item.setToolTip(status_text)
            self._table.setItem(row, self.STATUS_COLUMN, status_item)

        self._refreshing = False
        valid_count = sum(row.valid_edf for row in self._rows)
        self._count_label.setText(
            f"{len(entries)} EDF file(s), {valid_count} available to process"
        )
        self._current_label.setText("No batch running")
        self._current_progress.setFormat("Current file: no batch")
        self._current_progress.setValue(0)
        self._overall_progress.setRange(0, max(valid_count, 1))
        self._overall_progress.setValue(0)
        self._overall_progress.setFormat("Overall: no batch")
        self._refresh_validation()

        if not entries:
            QMessageBox.information(
                self,
                "No EDF files found",
                "No .edf files were found directly inside the selected folder.",
            )

    @Slot(QTableWidgetItem)
    def _item_changed(self, item: QTableWidgetItem) -> None:
        user_column = item.column() in (
            self.PROCESS_COLUMN,
            self.STUDY_ID_COLUMN,
        )
        if (
            user_column
            and not self._refreshing
            and not self._busy
            and not self._run_locked
        ):
            self._refresh_validation()

    def _set_status(self, row: int, text: str, color: QColor) -> None:
        item = self._table.item(row, self.STATUS_COLUMN)
        item.setText(text)
        item.setToolTip(text)
        item.setForeground(color)

    def _refresh_validation(self) -> None:
        if self._refreshing or self._busy or self._run_locked:
            self._update_controls()
            return

        self._refreshing = True
        checked: list[int] = []
        study_ids: dict[int, str] = {}
        problems: dict[int, str] = {}

        for row, row_data in enumerate(self._rows):
            if not row_data.valid_edf:
                continue
            process_item = self._table.item(row, self.PROCESS_COLUMN)
            if process_item.checkState() != Qt.CheckState.Checked:
                continue
            checked.append(row)
            study_id = self._table.item(row, self.STUDY_ID_COLUMN).text()
            try:
                study_ids[row] = validate_study_id(study_id)
            except EdfError as exc:
                problems[row] = _message(exc, limit=150)

        target_rows: dict[str, list[int]] = {}
        for row, study_id in study_ids.items():
            target_rows.setdefault(f"{study_id}.edf".casefold(), []).append(row)

        source_rows: dict[str, list[int]] = {}
        for row in checked:
            source_rows.setdefault(
                self._rows[row].path.name.casefold(), []
            ).append(row)
        for rows in source_rows.values():
            if len(rows) > 1:
                for row in rows:
                    problems[row] = (
                        "Source filenames differ only by capitalization"
                    )

        for target_name, rows in target_rows.items():
            if len(rows) > 1:
                for row in rows:
                    problems[row] = "Duplicate output filename in selected rows"
                continue
            row = rows[0]
            row_data = self._rows[row]
            conflicts = tuple(
                path
                for path in self._existing_names.get(target_name, ())
                if path != row_data.path
            )
            if conflicts:
                problems[row] = (
                    f"Output filename conflicts with {conflicts[0].name}"
                )

        for row, row_data in enumerate(self._rows):
            if not row_data.valid_edf:
                continue
            process_item = self._table.item(row, self.PROCESS_COLUMN)
            if process_item.checkState() != Qt.CheckState.Checked:
                self._set_status(row, "Not selected", QColor("#666666"))
            elif row in problems:
                self._set_status(row, problems[row], QColor("#b00020"))
            else:
                self._set_status(row, "Ready", QColor("#177245"))

        self._refreshing = False
        self._confirm_button.setEnabled(bool(checked) and not problems)
        self._update_controls()

    def _set_all_checked(self, checked: bool) -> None:
        if self._busy or self._run_locked:
            return
        self._refreshing = True
        state = Qt.CheckState.Checked if checked else Qt.CheckState.Unchecked
        for row, row_data in enumerate(self._rows):
            if row_data.valid_edf:
                self._table.item(row, self.PROCESS_COLUMN).setCheckState(state)
        self._refreshing = False
        self._refresh_validation()

    def _selected_rows(self) -> list[tuple[int, _Row, str]]:
        selected: list[tuple[int, _Row, str]] = []
        for row, row_data in enumerate(self._rows):
            if not row_data.valid_edf:
                continue
            if (
                self._table.item(row, self.PROCESS_COLUMN).checkState()
                != Qt.CheckState.Checked
            ):
                continue
            study_id = self._table.item(row, self.STUDY_ID_COLUMN).text()
            selected.append((row, row_data, study_id))
        return selected

    @Slot()
    def _confirm_batch(self) -> None:
        self._refresh_validation()
        if not self._confirm_button.isEnabled():
            return

        selected = self._selected_rows()
        jobs = tuple(
            DeidentificationJob(row_data.path, study_id)
            for _, row_data, study_id in selected
        )
        try:
            plan = preflight_batch(jobs)
        except EdfError as exc:
            issues = tuple(getattr(exc, "issues", ()))
            selected_paths = {
                row_data.path: row for row, row_data, _ in selected
            }
            messages: dict[int, list[str]] = {}
            global_messages: list[str] = []
            for issue in issues:
                issue_path = getattr(issue, "path", None)
                issue_message = _message(issue, limit=150)
                if issue_path in selected_paths:
                    messages.setdefault(selected_paths[issue_path], []).append(
                        issue_message
                    )
                else:
                    global_messages.append(issue_message)
            if not issues:
                global_messages.append(_message(exc, limit=150))

            self._refreshing = True
            for row, _, _ in selected:
                row_messages = messages.get(row, []) + global_messages
                if row_messages:
                    self._set_status(
                        row,
                        f"Preflight: {'; '.join(row_messages)}",
                        QColor("#b00020"),
                    )
            self._refreshing = False
            self._confirm_button.setEnabled(False)

            path = getattr(exc, "path", None)
            path_line = f"\nFile: {path}" if path else ""
            QMessageBox.critical(
                self,
                "Cannot start batch",
                f"Preflight failed at {_stage_label(_stage(exc))}.{path_line}"
                f"\n\n{_message(exc)}"
                f"\n\nTemporary-file cleanup: {_cleanup(exc, 'Not needed')}",
            )
            return

        confirmation = QMessageBox(self)
        confirmation.setIcon(QMessageBox.Icon.Warning)
        confirmation.setWindowTitle("Confirm irreversible changes")
        confirmation.setText(
            f"Deidentify and rename {len(selected)} EDF file(s) in place?"
        )
        confirmation.setInformativeText(
            "Original patient IDs and filenames will not be recoverable. "
            "Close other programs using this folder and pause folder "
            "synchronization until the result dialog appears."
        )
        cancel_button = confirmation.addButton(
            QMessageBox.StandardButton.Cancel
        )
        start_button = confirmation.addButton(
            f"Deidentify {len(selected)} file(s)",
            QMessageBox.ButtonRole.DestructiveRole,
        )
        confirmation.setDefaultButton(cancel_button)
        confirmation.exec()
        if confirmation.clickedButton() is not start_button:
            return

        prepared = tuple(plan.jobs)
        if len(prepared) != len(selected):
            QMessageBox.critical(
                self,
                "Cannot start batch",
                "The preflight result did not match the selected files. "
                "No files were changed.",
            )
            return

        prepared_rows = tuple(
            (
                row,
                prepared_job,
                row_data.path.name,
                f"{study_id}.edf",
            )
            for (row, row_data, study_id), prepared_job in zip(selected, prepared)
        )
        self._start_worker(prepared_rows)

    def _start_worker(
        self,
        prepared_rows: Sequence[tuple[int, object, str, str]],
    ) -> None:
        self._busy = True
        self._run_locked = True
        self._finished_count = 0
        self._pending_results = ()
        self._pending_stopped = False
        self._pending_failed = False
        self._overall_progress.setRange(0, len(prepared_rows))
        self._overall_progress.setValue(0)
        self._overall_progress.setFormat("Overall: %v of %m files")
        self._current_progress.setFormat("Current file: %p%")
        self._current_progress.setValue(0)

        self._refreshing = True
        for row, _, _, _ in prepared_rows:
            self._set_status(row, "Queued", QColor("#555555"))
        self._refreshing = False

        thread = QThread(self)
        worker = _BatchWorker(prepared_rows)
        worker.moveToThread(thread)
        thread.started.connect(worker.run)
        worker.file_started.connect(self._file_started)
        worker.progress_changed.connect(self._progress_changed)
        worker.outcome_ready.connect(self._outcome_ready)
        worker.finished.connect(self._batch_finished)
        worker.finished.connect(thread.quit)
        worker.finished.connect(worker.deleteLater)
        thread.finished.connect(self._thread_finished)
        thread.finished.connect(thread.deleteLater)
        self._thread = thread
        self._worker = worker
        self._update_controls()
        thread.start()

    @Slot(int, str, int, int)
    def _file_started(
        self, row: int, filename: str, index: int, total: int
    ) -> None:
        self._current_label.setText(
            f"File {index} of {total}: {filename}"
        )
        self._current_progress.setValue(0)
        self._set_status(row, "Processing", QColor("#174ea6"))

    @Slot(int, str, object, object)
    def _progress_changed(
        self, row: int, stage: str, completed: object, total: object
    ) -> None:
        try:
            completed_value = int(completed)
            total_value = int(total)
        except (TypeError, ValueError):
            completed_value = 0
            total_value = 0
        fraction = (
            min(max(completed_value / total_value, 0.0), 1.0)
            if total_value > 0
            else 0.0
        )
        self._current_progress.setValue(round(fraction * 1000))
        label = _stage_label(stage)
        self._current_progress.setFormat(f"{label}: %p%")
        self._set_status(row, label, QColor("#174ea6"))

    @Slot(object)
    def _outcome_ready(self, outcome: _Outcome) -> None:
        self._finished_count += 1
        self._overall_progress.setValue(self._finished_count)
        if outcome.result == "completed":
            self._set_status(
                outcome.row,
                f"Completed → {outcome.target_filename}",
                QColor("#177245"),
            )
        elif outcome.result == "failed":
            self._set_status(
                outcome.row,
                f"Failed at {_stage_label(outcome.stage)}: "
                f"{_message(outcome.error, limit=100)}",
                QColor("#b00020"),
            )
        else:
            self._set_status(
                outcome.row,
                f"Untouched: {_message(outcome.error, limit=110)}",
                QColor("#666666"),
            )

    @Slot(object, bool, bool)
    def _batch_finished(
        self,
        outcomes: Sequence[_Outcome],
        stopped: bool,
        failed: bool,
    ) -> None:
        self._pending_results = tuple(outcomes)
        self._pending_stopped = stopped
        self._pending_failed = failed

    @Slot()
    def _thread_finished(self) -> None:
        self._thread = None
        self._worker = None
        self._busy = False

        for row, row_data in enumerate(self._rows):
            if not row_data.valid_edf:
                continue
            process_item = self._table.item(row, self.PROCESS_COLUMN)
            process_item.setFlags(Qt.ItemFlag.NoItemFlags)
            study_item = self._table.item(row, self.STUDY_ID_COLUMN)
            study_item.setFlags(Qt.ItemFlag.NoItemFlags)

        if self._pending_failed:
            self._current_label.setText(
                "Batch stopped after an error; remaining files were untouched"
            )
        elif self._pending_stopped:
            self._current_label.setText(
                "Batch stopped safely; remaining files were untouched"
            )
        else:
            self._current_label.setText("Batch completed")
            self._current_progress.setValue(1000)

        self._update_controls()
        _ResultsDialog(self._pending_results, self).exec()

        if self._close_after_batch:
            self._close_after_batch = False
            self.close()

    @Slot()
    def request_stop(self) -> None:
        if self._worker is None:
            return
        self._worker.request_stop()
        self._stop_button.setEnabled(False)
        self._current_label.setText(
            "Stopping safely after the current safe boundary…"
        )

    def _update_controls(self) -> None:
        editable = not self._busy and not self._run_locked
        any_valid = any(row.valid_edf for row in self._rows)
        self._select_folder_button.setEnabled(not self._busy)
        self._check_all_button.setEnabled(editable and any_valid)
        self._uncheck_all_button.setEnabled(editable and any_valid)
        self._table.setEnabled(not self._busy)
        self._stop_button.setEnabled(self._busy)
        if self._busy or self._run_locked:
            self._confirm_button.setEnabled(False)

    def closeEvent(self, event: QCloseEvent) -> None:  # noqa: N802
        if not self._busy:
            event.accept()
            return

        answer = QMessageBox.question(
            self,
            "Batch in progress",
            "Stop safely and close after temporary-file cleanup?\n\n"
            "Files already completed will remain deidentified.",
            QMessageBox.StandardButton.Yes | QMessageBox.StandardButton.No,
            QMessageBox.StandardButton.No,
        )
        if answer == QMessageBox.StandardButton.Yes:
            self._close_after_batch = True
            self.request_stop()
        event.ignore()


def main(argv: Sequence[str] | None = None) -> int:
    app = QApplication(list(argv) if argv is not None else sys.argv)
    app.setApplicationName("EDF Deidentifier")
    app.setOrganizationName("EDF Deidentifier")
    window = MainWindow()
    window.show()
    QTimer.singleShot(0, window.choose_folder)
    return app.exec()


__all__ = ["MainWindow", "main"]
