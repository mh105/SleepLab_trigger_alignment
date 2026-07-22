function tests = test_concatenate_eeg_segments
tests = functiontests(localfunctions);
end

function setupOnce(~)
project_path = fileparts(fileparts(mfilename('fullpath')));
addpath(project_path)
addpath(fullfile(project_path, 'helper_functions'))
end

function testPadsBeforeBetweenAndAfterSegments(testCase)
segment_1 = single(repmat(1:3, 11, 1) + (0:10)' * 10);
segment_2 = single(repmat(4:6, 11, 1) + (0:10)' * 10);
eeg_segment_data = {segment_1; segment_2};
matched_segments = table( ...
    [3; 7], [4; 8], ...
    'VariableNames', {'edf_start_sample', 'edf_end_sample'});
edf_input.Fs = 256;
edf_input.trigger_Fs = 128;
edf_input.aligned_eeg_channel_names = { ...
    'Fp1', 'Fp2', 'F3', 'F4', 'C3', ...
    'C4', 'O1', 'O2', 'M1', 'M2', 'VEOGL'};
edf_input.edf_eeg_total_sample_count = 20;

final_eeg_data = concatenate_eeg_segments( ...
    eeg_segment_data, matched_segments, edf_input);

expected = zeros( ...
    11, edf_input.edf_eeg_total_sample_count, 'single');
expected(:, 5:7) = segment_1;
expected(:, 13:15) = segment_2;
verifyEqual(testCase, final_eeg_data, expected)
verifySize(testCase, final_eeg_data, ...
    [11 edf_input.edf_eeg_total_sample_count])
verifyEqual(testCase, final_eeg_data(11, [1:4 8:12 16:20]), ...
    zeros(1, 14, 'single'))
verifyClass(testCase, final_eeg_data, 'single')
end
