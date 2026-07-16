function tests = test_truncate_eeg_segments
tests = functiontests(localfunctions);
end

function setupOnce(~)
addpath(fileparts(fileparts(mfilename('fullpath'))))
end

function testExtractsEverySegmentInRequestedChannelOrder(testCase)
source_channel_names = { ...
    'unused', 'RR2', 'L1', 'RD6', 'LA2', 'LL11', ...
    'R1', 'LD6', 'RA2', 'LL2', 'RR11'};
eeg_input = make_eeg_input(source_channel_names, 12);
matched_segments = table([2; 8], [5; 10], ...
    'VariableNames', {'eeg_start_sample', 'eeg_end_sample'});
edf_channel_names = { ...
    'Fp1', 'Fp2', 'F3', 'F4', 'C3', ...
    'C4', 'O1', 'O2', 'M1', 'M2'};
eeg_input.edf_eeg_channel_names = edf_channel_names;
expected_channel_index = [3 7 10 2 5 9 6 11 8 4];

eeg_segment_data = truncate_eeg_segments( ...
    matched_segments, eeg_input);

verifySize(testCase, eeg_segment_data, [2 1])
verifyEqual(testCase, eeg_segment_data{1}, ...
    eeg_input.EEG.data(expected_channel_index, 2:5))
verifyEqual(testCase, eeg_segment_data{2}, ...
    eeg_input.EEG.data(expected_channel_index, 8:10))
verifySize(testCase, eeg_segment_data{1}, [10 4])
verifySize(testCase, eeg_segment_data{2}, [10 3])
verifyClass(testCase, eeg_segment_data{1}, 'single')
end

function testMissingMappedHdEegChannelFails(testCase)
source_channel_names = { ...
    'L1', 'R1', 'LA2', 'RA2', 'LD6', ...
    'RD6', 'LL11', 'RR11', 'LL2'};
eeg_input = make_eeg_input(source_channel_names, 5);
matched_segments = table(1, 5, ...
    'VariableNames', {'eeg_start_sample', 'eeg_end_sample'});
edf_channel_names = { ...
    'Fp1', 'Fp2', 'F3', 'F4', 'C3', ...
    'C4', 'O1', 'O2', 'M1', 'M2'};
eeg_input.edf_eeg_channel_names = edf_channel_names;

verifyError(testCase, @() truncate_eeg_segments( ...
    matched_segments, eeg_input), ...
    'truncate_eeg_segments:MissingChannel')
end

function eeg_input = make_eeg_input(channel_names, n_samples)
for channel_i = numel(channel_names):-1:1
    chanlocs(channel_i).labels = channel_names{channel_i};
end
eeg_input.EEG.chanlocs = chanlocs;
eeg_input.EEG.data = single(reshape( ...
    1:(numel(channel_names) * n_samples), ...
    numel(channel_names), n_samples));
end
