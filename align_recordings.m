function [] = align_recordings(subject_code, trig_channel)
%% Sleep and EEG Recording Alignment with Stochastic (all night) Triggers
% Assumes that you have triggers throughout the night and 
% Last edit by Alex He 07/15/2026

%%%%%%%%%%%%%%%% Change these parameters

subject_code='sas_023';
trig_channel='TcPPG';

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%
if nargin < 2
    trig_channel = 'TcPPG';
end

%% Configuration
addpath('~/Dropbox/Active_projects/EEG/code/sleepeeg_code')
addpath('~/Dropbox/Active_projects/EEG/code/sleepeeg_code/helper_functions')
addpath('~/Dropbox/Active_projects/EEG/code/ant_interface_code')
addpath('helper_functions')

fpath = pwd;
fn_eeg = fullfile(fpath, subject_code, 'set', [subject_code '_sleep_ds500_Z3.set']);
fn_edf = fullfile(fpath, subject_code, 'clinical', 'HODRICK_ROBERT_(1).edf');

progress_steps = {'EDF trigger channel loaded'; 'HD-EEG data loaded'; 'Clinical EDF data loaded'; 'Triggers extracted and matched'; 'HD-EEG channels truncated'; 'HD-EEG channels resampled'; 'Aligned segments concatenated and padded'; 'Direct EDF montage signals prepared'; 'Final sanity checks completed'; 'Aligned EDF saved'};
progress_step_count = numel(progress_steps);
mark_step_done = @(step_i) fprintf('  [%s%s] %2d/%d  [done] %s\n', repmat('=', 1, step_i), repmat('-', 1, progress_step_count - step_i), step_i, progress_step_count, progress_steps{step_i});

fprintf('\nAlignment checklist\n')
fprintf('  [%s] %2d/%d  [ ] Ready\n', repmat('-', 1, progress_step_count), 0, progress_step_count)

%% Load all data
% Load the trigger channel from EDF file
[header, signalHeader, signalCell] = SleepEEG_loadedf(fn_edf, {trig_channel});
trigger_Fs = signalHeader.samples_in_record ./ header.data_record_duration;
mark_step_done(1);

% Load the HD-EEG data so we can get the trigger events
[filepath, filename_no_ext, ext] = fileparts(fn_eeg);
filename = [filename_no_ext ext];
EEG = ANT_interface_loadset(filename, filepath, false);

% figure out scalp channel sampling rate in HD-EEG file
eeg_Fs = EEG.srate;

% assert the HD-EEG sampling rate
assert(eeg_Fs == 500, 'EEG sampling rate is different from 500Hz.')
mark_step_done(2);

% Load all channels from EDF file
[header_all, signalHeader_all, signalCell_all] = SleepEEG_loadedf(fn_edf);

% figure out scalp channel sampling rate in the EDF file
c3_index = strcmp({signalHeader_all.signal_labels}, 'C3');
edf_Fs = signalHeader_all(c3_index).samples_in_record / header_all.data_record_duration;

% assert the EDF sampling rate
assert(edf_Fs == 256, 'EDF sampling rate is different from 256Hz.')
mark_step_done(3);

%% Extract triggers from the two files and match by trigger intervals
% Create two structs to hold useful variables
edf_input.DC_trace = signalCell{1};
edf_input.trigger_Fs = trigger_Fs;
edf_input.Fs = edf_Fs;

eeg_input.EEG = EEG;
eeg_input.Fs = eeg_Fs;

% a) extract triggers from the HD-EEG events and EDF trigger channel 
[eeg_input, edf_input] = extract_triggers(eeg_input, edf_input, true);

% b) match trigger intervals between the two systems
[trigger_match_result, eeg_input, edf_input] = match_triggers(eeg_input, edf_input, true);

% c) extract continuous matched-up segments based on matched-up trigger intervals
matched_segments = extract_segments(trigger_match_result, eeg_input, edf_input, true);
mark_step_done(4);

%% Truncate relevant HD-EEG channels to within segment sample bounds
edf_eeg_channel_names = {'Fp1', 'Fp2', 'F3', 'F4', 'C3', 'C4', 'O1', 'O2'};
% HD-EEG M1/M2 are retained only as reference sources. Clinical E1, E2,
% M1, and M2 retain their recorded signals but are requantized below.
% VEOGL is retained for QA.
aligned_eeg_channel_names = [edf_eeg_channel_names, {'M1', 'M2', 'VEOGL'}];
eeg_input.aligned_eeg_channel_names = aligned_eeg_channel_names;
eeg_segment_data = truncate_eeg_segments(matched_segments, eeg_input);
mark_step_done(5);

%% Resample HD-EEG signal into EDF sampling rate
% Treat the EDF clock as the reference and estimate the effective HD-EEG
% sampling rate separately for each continuous matched segment.
edf_input.aligned_eeg_channel_names = aligned_eeg_channel_names;
resampled_eeg_segment_data = resample_eeg_segments(eeg_segment_data, matched_segments, edf_input, true);
mark_step_done(6);

%% Concatenate with zero padding to the same length as the entire EDF length
edf_input.edf_eeg_total_sample_count = numel(signalCell_all{c3_index});
final_eeg_data = concatenate_eeg_segments(resampled_eeg_segment_data, matched_segments, edf_input);
mark_step_done(7);

%% Insert the EEG channel data into EDF file
% Put all direct montage channels on one EDF voltage grid, then prepare the
% 8 grounded scalp signals using the requantized clinical mastoids.
[signalHeader_final, signalCell_final] = quantize_edf_data(signalHeader_all, signalCell_all);
signalCell_final = substitute_eeg_data(final_eeg_data, edf_eeg_channel_names, aligned_eeg_channel_names, signalHeader_final, signalCell_final, true);
mark_step_done(8);

%% Final sanity check plots
% a) Compare native C3:M2 with C3:M2 reconstructed from grounded EDF rows
sanity_check_spectrogram(EEG, header_all, signalHeader_final, signalCell_final);

% b) Compare referenced HD-EEG and clinical EOG signals
sanity_check_EOG(final_eeg_data, aligned_eeg_channel_names, signalHeader_final, signalCell_final, edf_Fs);
mark_step_done(9);

%% Save aligned EDF file 
edfFN = strrep(fn_edf, '.edf', '_aligned.edf');
blockEdfWrite(edfFN, header_all, signalHeader_final, signalCell_final);
mark_step_done(10);
fprintf('\nAlignment complete.\n')

end
