function [ figure_cleanup ] = align_recordings(subject_code, trig_channel)
%% Sleep and EEG Recording Alignment with Stochastic (all night) Triggers
% Last edit by Alex He 08/07/2026

if nargin < 2
    trig_channel = 'TcPPG';
end

figure_cleanup = {};

%% Configuration
dataDir = SleepEEG_addpath(matlabroot, 'sas');

if isempty(which('extract_triggers'))
    repo_root = fileparts(which('align_recordings'));
    addpath(genpath(fullfile(repo_root, 'helper_functions')))
end

fn_eeg = fullfile(dataDir, subject_code, 'set', [subject_code '_sleep_ds500_Z3.set']);
fn_edf = fullfile(dataDir, subject_code, 'clinical', [subject_code, '.edf']);
clinical_directory = fileparts(fn_edf);
execution_datetime = char(datetime('now', 'Format', 'yyyyMMdd_HHmmss'));
alignment_log_file = fullfile(clinical_directory, [subject_code '_alignment_' execution_datetime '.log']);
diary(alignment_log_file)
diary_cleanup = onCleanup(@() diary('off'));

progress_steps = { ...
    'EDF trigger channel loaded'; ...
    'HD-EEG data loaded'; ...
    'Clinical EDF data loaded'; ...
    'Triggers extracted and matched'; ...
    'HD-EEG channels truncated'; ...
    'HD-EEG channels resampled'; ...
    'Aligned segments concatenated and padded'; ...
    'Final output EDF channels prepared'; ...
    'Final sanity checks completed'; ...
    'Aligned EDF saved'};
progress_step_count = numel(progress_steps);
mark_step_done = @(step_i) fprintf('  [%s%s] %2d/%d  [done] %s\n', repmat('=', 1, step_i), repmat('-', 1, progress_step_count - step_i), step_i, progress_step_count, progress_steps{step_i});

fprintf('\nAlignment checklist\n')
fprintf('  [%s] %2d/%d  [ ] Ready\n', repmat('-', 1, progress_step_count), 0, progress_step_count)

%% Load all data
% 1) Load the trigger channel from EDF file
[header, signalHeader, signalCell] = SleepEEG_loadedf(fn_edf, {trig_channel});
trigger_Fs = signalHeader.samples_in_record ./ header.data_record_duration;
assert(trigger_Fs == 128, 'EDF trigger channel sampling rate is different from 128Hz.')
mark_step_done(1);

% 2) Load the HD-EEG data so we can get the trigger events
[filepath, filename_no_ext, ext] = fileparts(fn_eeg);
filename = [filename_no_ext ext];
EEG = ANT_interface_loadset(filename, filepath, false);
eeg_Fs = EEG.srate;
assert(eeg_Fs == 500, 'EEG sampling rate is different from 500Hz.')
mark_step_done(2);

% 3) Load all channels from EDF file
[header_all, signalHeader_all, signalCell_all] = SleepEEG_loadedf(fn_edf);
c3_index = strcmp({signalHeader_all.signal_labels}, 'C3');
edf_Fs = signalHeader_all(c3_index).samples_in_record / header_all.data_record_duration;
assert(edf_Fs == 256, 'EDF sampling rate is different from 256Hz.')
sanity_figure_handle = sanity_plot_EDF_data(signalCell_all{c3_index}, signalCell{1}, edf_Fs, trigger_Fs);
figure_cleanup{end + 1} = save_and_track_alignment_figure(sanity_figure_handle, clinical_directory, subject_code, 3, 'clinical_c3_trigger');
mark_step_done(3);

%% Extract triggers from the two files and match by trigger intervals
% Create two structs to hold useful variables
edf_input.DC_trace = signalCell{1}; edf_input.trigger_Fs = trigger_Fs; edf_input.Fs = edf_Fs;
eeg_input.EEG = EEG; eeg_input.Fs = eeg_Fs;

% 4.1) extract triggers from the HD-EEG events and EDF trigger channel
[eeg_input, edf_input, sanity_figure_handle] = extract_triggers(eeg_input, edf_input, true);
figure_cleanup{end + 1} = save_and_track_alignment_figure(sanity_figure_handle, clinical_directory, subject_code, 4, '1_trigger_intervals');

% 4.2) match trigger intervals between the two systems
[trigger_match_result, eeg_input, edf_input, sanity_figure_handle] = match_triggers(eeg_input, edf_input, true);
figure_cleanup{end + 1} = save_and_track_alignment_figure(sanity_figure_handle, clinical_directory, subject_code, 4, '2_trigger_alignment');

% 4.3) extract continuous matched-up segments based on matched-up trigger intervals
[matched_segments, sanity_figure_handle] = extract_segments(trigger_match_result, eeg_input, edf_input, true);
figure_cleanup{end + 1} = save_and_track_alignment_figure(sanity_figure_handle, clinical_directory, subject_code, 4, '3_clock_drift');
mark_step_done(4);

%% Truncate relevant HD-EEG channels to within segment sample bounds
edf_eeg_channel_names = {'Fp1', 'Fp2', 'F3', 'F4', 'C3', 'C4', 'O1', 'O2'};
aligned_eeg_channel_names = [edf_eeg_channel_names, {'M1', 'M2', 'VEOGL'}];
eeg_segment_data = truncate_eeg_segments(matched_segments, eeg_input, aligned_eeg_channel_names);
mark_step_done(5);

%% Resample HD-EEG signal into EDF sampling rate
% Treat the EDF clock as the reference and estimate the effective HD-EEG
% sampling rate separately for each continuous matched segment.
[resampled_eeg_segment_data, resampling_figure_handles] = resample_eeg_segments(eeg_segment_data, matched_segments, edf_input, aligned_eeg_channel_names, true);
figure_cleanup{end + 1} = save_and_track_alignment_figure(reshape([resampling_figure_handles.trace(:).'; resampling_figure_handles.spectrum(:).'], [], 1), clinical_directory, subject_code, 6, reshape([compose("seg%02d_1_trace", 1:height(matched_segments)); compose("seg%02d_2_spectrum", 1:height(matched_segments))], [], 1));
mark_step_done(6);

%% Concatenate with zero padding to the same length as the entire EDF length
edf_input.edf_eeg_total_sample_count = numel(signalCell_all{c3_index});
[aligned_eeg_data, matched_edf_sample_mask] = concatenate_eeg_segments(resampled_eeg_segment_data, matched_segments, edf_input, aligned_eeg_channel_names);
mark_step_done(7);

%% Insert the EEG channel data into EDF file
% Detect faulty clinical mastoids only within trustworthy matched regions.
clinical_system_faulty = faulty_clinical_detection(signalHeader_all, signalCell_all, matched_edf_sample_mask);

% Prepare the 12 final output channels without changing any EDF headers.
[signalCell_final, sanity_figure_handle] = substitute_eeg_data(aligned_eeg_data, aligned_eeg_channel_names, edf_eeg_channel_names, signalHeader_all, signalCell_all, clinical_system_faulty, matched_edf_sample_mask, true);
figure_cleanup{end + 1} = save_and_track_alignment_figure(sanity_figure_handle, clinical_directory, subject_code, 8, 'scalp_substitution');
mark_step_done(8);

%% Final sanity check plots
% a) Compare native C3:M2 with C3:M2 reconstructed from grounded EDF rows
sanity_figure_handle = sanity_check_spectrogram(EEG, header_all, signalHeader_all, signalCell_final);
figure_cleanup{end + 1} = save_and_track_alignment_figure(sanity_figure_handle, clinical_directory, subject_code, 9, '1_spectrogram');

% b) Compare referenced HD-EEG and clinical EOG signals
sanity_figure_handle = sanity_check_EOG(aligned_eeg_data, aligned_eeg_channel_names, signalHeader_all, signalCell_all, edf_Fs);
figure_cleanup{end + 1} = save_and_track_alignment_figure(sanity_figure_handle, clinical_directory, subject_code, 9, '2_eog');
mark_step_done(9);

%% Save aligned EDF file
edfFN = strrep(fn_edf, '.edf', '_aligned.edf');
blockEdfWrite(edfFN, header_all, signalHeader_all, signalCell_final);
mark_step_done(10);

fprintf('\nAlignment complete.\n')

% An uncaptured output would otherwise persist in ans and keep figures open.
if nargout == 0
    figure_cleanup = {};
end

end
