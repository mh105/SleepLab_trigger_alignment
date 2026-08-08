function tests = test_initialize_alignment_inputs
tests = functiontests(localfunctions);
end

function setupOnce(~)
project_path = fileparts(fileparts(mfilename('fullpath')));
addpath(fullfile(project_path, 'helper_functions'))
end

function testCreatesBothInputStructs(testCase)
EEG.data = single([1, 2, 3]);
EEG.srate = 500;
eeg_Fs = 500;
edf_dc_trace = int16([10; 20; 30]);
trigger_Fs = 128;
edf_Fs = 256;

[eeg_input, edf_input] = initialize_alignment_inputs(EEG, eeg_Fs, edf_dc_trace, trigger_Fs, edf_Fs);

verifyEqual(testCase, fieldnames(eeg_input), {'EEG'; 'Fs'})
verifyEqual(testCase, eeg_input.EEG, EEG)
verifyEqual(testCase, eeg_input.Fs, eeg_Fs)
verifyEqual(testCase, fieldnames(edf_input), {'DC_trace'; 'trigger_Fs'; 'Fs'})
verifyEqual(testCase, edf_input.DC_trace, edf_dc_trace)
verifyEqual(testCase, edf_input.trigger_Fs, trigger_Fs)
verifyEqual(testCase, edf_input.Fs, edf_Fs)
end
