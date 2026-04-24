# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this code does

MATLAB pipeline that aligns a **clinical Natus sleep EEG** recording (sampled at 512 Hz, stored as EDF) with a **research HD-EEG** recording (128+ channels, downsampled to 500 Hz, stored as an EEGLAB `.set`). Alignment is achieved via a DC trigger channel with stochastic pulses placed throughout the night plus short "start" / "end" sequences (4 tightly-spaced triggers). The output is a single aligned EDF containing 6 HD-EEG montage channels + mastoid refs + all clinical polysomnography channels + the original EDF annotation channel, on the HD-EEG time base.

## How to run

All entry points are MATLAB functions that must be called from a MATLAB session with the lab's cluster paths mounted. The primary entry point is:

```matlab
align_recordings(subject_code, night, trig_channel, end_seq)
% e.g. align_recordings('CBAN_F_56', '1', 'DC7', true)
```

- `subject_code`: e.g. `'CBAN_F_56'` — used to build filesystem paths under `/autofs/cifs/adsleepeeg/archive/subject_data/<subject_code>/`
- `night`: numeric night string, e.g. `'1'`
- `trig_channel`: name of the DC channel in the Natus EDF carrying triggers, e.g. `'DC7'`
- `end_seq`: `true` if the recording has a terminal 4-trigger sequence, `false` if not

There is no build/test/lint step — it's a single-script pipeline.

`refactored_trigger_alignment.m` is an older variant kept for reference; `align_recordings.m` is the current version (last edited 2022-08-01). Changes should go into `align_recordings.m`.

## External dependencies

The scripts `addpath` three cluster locations — none of them live in this repo, and the code will not run without them mounted:

- `/autofs/cluster/purdonlab/code/matlab/eeg_analysis` — EEGLAB + helpers (`eeg_eventtable`, etc.)
- `/autofs/cifs/adsleepeeg/code/sleepeeg_code` — provides `SleepEEG_loadedf`, `SleepEEG_loadset`, `SleepEEG_buildannot`
- `/autofs/cifs/adsleepeeg/code/sleepeeg_code/EDF_Deidentification_updated/` — provides `blockEdfWrite`

Expected input layout under `/autofs/cifs/adsleepeeg/archive/subject_data/<subject>/`:
- `set/<subject>_night<N>_Sleep_ds500_Z3.set` — HD-EEG
- `clinical/<subject>_night<N>_Sleep_clinical_deidentified.edf` — Natus

Outputs are written alongside the clinical EDF: `<subject>_night<N>_aligned.edf`, `<subject>_night<N>_rvsalign.mat`, and per-channel QA PNGs + an `_EOG_compare.fig`.

## Pipeline architecture

`align_recordings.m` orchestrates the whole flow; the other files are small helpers. The steps, in order:

1. **Load both recordings** → `SleepEEG_loadedf` for the clinical EDF (first only the DC trigger channel, later the full PSG channel list), `SleepEEG_loadset` for the HD-EEG `.set`.
2. **Detect triggers on each system** → `record_summary.m` wraps this. Sleep triggers come from `identify_sleep_trig.m` (rising edges >1 V on the DC channel, deduplicated to ≥1 sample apart). HD-EEG triggers come from the EEGLAB event table. Both are returned as sample-index vectors.
3. **Compute inter-trigger intervals in minutes** → `trig_distances.m` (just `diff(idx)/(Fs*60)`). Used both for start/end-sequence detection and for interval matching.
4. **Find start/end 4-pulse sequences** → `start_sequence.m` looks for three consecutive inter-trigger gaps in the range `0.0332–0.0335` min (~2 s). Each hit returns the 4 trigger indices defining that sequence. Normally there are exactly 2 sequences (start and end), with columns `[start end]`. If not, the script prompts the user interactively with `input()` to pick the correct column index; this is the most common point of manual intervention.
5. **Truncate the trigger list** to live between the chosen start and end sequences. The code anchors on the **3rd** trigger of each 4-pulse sequence (`sequence_index = 3`) so there is always a full interval on each side to match against.
6. **Match intervals across systems** → a two-loop process on the interval vectors. The outer loop walks sleep intervals; if the next EEG interval is within `0.1` min it's a match, otherwise it records a gap and searches forward in the EEG intervals (with a tighter `0.0002` min tolerance) to re-sync. The inner loop is bounded so a "double-bad" interval in a row doesn't deadlock. The result is `compare_diff3` (per-sleep-interval view) and `compare_diff2` (per-EEG-interval view), then `match_global` = `[eeg_trig_idx, sleep_trig_idx]` for every matched trigger.
7. **Derive per-chunk start/end indices** (`eeg_ss`, `sleep_ss`) by taking the contiguous runs of non-zero matches. A sanity check verifies each chunk's duration roughly matches between systems and that the inferred sleep sampling frequency is within 1 Hz of 512.
8. **Truncate HD-EEG data** to `eeg_ss(1,1) : eeg_ss(end,end)` and rebuild `EEG.event` with corresponding latencies.
9. **Resample clinical PSG onto HD-EEG time base** → `interp_to_eeg.m` does piecewise linear interpolation per interval: for each matched interval it builds a time stamp vector using the *EEG* interval duration spread over the *sleep* sample count, then `interp1`'s at the EEG sample times. NaNs from edge effects are zeroed.
10. **Extract 8 HD-EEG scalp channels** (F3, F4, C3, C4, O1, O2, M1E, M2E) by pulling specific ANT channel labels (`LL2`, `RR2`, `LA2`, `RA2`, `LL11`, `RR11`, `LD6`, `RD6`) via `extract_lead.m`. The mapping from ANT label → standard 10-20 name is hardcoded in `align_recordings.m`.
11. **Build the output header/signalHeader/signalCell** for `blockEdfWrite`:
    - 8 EEG channels first, then all clinical channels, then the EDF Annotations channel last.
    - EEG channels use a hardcoded ANT physical range `[-83886, 83886]` µV with digital range `[-32768, 32767]`. Values outside the physical range are clipped and a per-channel QA plot is saved to the subject's `clinical/` dir.
    - `samples_in_record = Fs/2 = 250` for EEG channels (EDF data records are 2 s long).
12. **Zero-pad to match the annotation channel length.** Because `num_data_records` in the EDF is fixed by the annotation channel, `beg_pad` (samples before the start sequence) and `end_pad` (remaining samples to fill the last data record) are prepended/appended to every non-annotation channel. An assert confirms total epoch counts match across channels — if it fails, the annotation channel won't write properly.
13. **Save `rvsalign_store`** — a `.mat` with `truncate_startidx`, `truncate_endidx`, `original_length`, `begin_pad`, `end_pad`. This is what downstream code needs to map a sample in the aligned EDF back to the original HD-EEG timeline. **Note**: in the current version (2022-08-01) the truncate indices are taken from `eeg_ss(1,1)` / `eeg_ss(end,end)`, not `match_global(1,1)` / `match_global(end,1)`. The older `refactored_trigger_alignment.m` uses the latter — don't copy that behavior back.
14. **Rebuild the annotation channel** via `SleepEEG_buildannot` and write the final EDF via `blockEdfWrite`.

## Things that frequently need manual fixing

The comment block at `align_recordings.m:54–62` calls this out: triggers get lost, start/end sequences don't always form cleanly, and the interactive `input()` prompts at lines 73–87 exist specifically so you can select the right sequence index by hand. If something fails downstream, the standard debugging workflow is to step through from the start-sequence section and manually set `sleep_start`/`sleep_end`/`eeg_start`/`eeg_end` (or even set one to `0` meaning "use beginning/end of recording").

## Coordinate systems to keep straight

- `trig_index` is in **samples** of the source system (512 Hz sleep, 500 Hz EEG).
- `trig_diff` is in **minutes** (that's what the `0.0332–0.0335` and `0.1` tolerances are expressed in).
- `match_global` columns: **col 1 is EEG sample index, col 2 is sleep sample index** — easy to flip.
- `EEG.times` from EEGLAB is in **milliseconds**, and `interp_to_eeg` mixes it with minute-scaled interval durations (`*60*1000`).
