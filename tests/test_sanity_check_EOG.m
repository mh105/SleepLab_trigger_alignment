function tests = test_sanity_check_EOG
tests = functiontests(localfunctions);
end

function setupOnce(~)
project_path = fileparts(fileparts(mfilename('fullpath')));
addpath(project_path)
addpath(fullfile(project_path, 'helper_functions'))
end

function testPlotsReferencedHdAndUnchangedClinicalEog(testCase)
[final_eeg_data, aligned_eeg_channel_names, ...
    signalHeader_final, signalCell_final, edf_Fs] = make_fixture;
signalCell_final = signalCell_final(:);
signalCell_before = signalCell_final;

original_visibility = get(groot, 'defaultFigureVisible');
visibility_cleanup = onCleanup(@() set( ...
    groot, 'defaultFigureVisible', original_visibility));
set(groot, 'defaultFigureVisible', 'off')

figure_handle = sanity_check_EOG( ...
    final_eeg_data, aligned_eeg_channel_names, ...
    signalHeader_final, signalCell_final, edf_Fs);
figure_cleanup = onCleanup(@() delete(figure_handle));

verifyEqual(testCase, figure_handle.Tag, 'sanity_check_EOG')
axes_handles = findall( ...
    figure_handle, 'Type', 'axes', ...
    'Tag', 'sanity_check_EOG_axes');
line_handles = findall(figure_handle, 'Type', 'line');
verifyNumElements(testCase, axes_handles, 4)
verifyNumElements(testCase, line_handles, 4)
for axes_i = 1:numel(axes_handles)
    verifyEqual(testCase, ...
        char(axes_handles(axes_i).InteractionOptions.DatatipsSupported), ...
        'off')
    verifyEqual(testCase, ...
        char(axes_handles(axes_i).InteractionOptions.ZoomSupported), 'on')
end

expected_time_hours = ...
    (0:(size(final_eeg_data, 2) - 1)) / (edf_Fs * 3600);
veogl_index = strcmp(aligned_eeg_channel_names, 'VEOGL');
m2_index = strcmp(aligned_eeg_channel_names, 'M2');
expected_hd_eog = ...
    final_eeg_data(veogl_index, :) - final_eeg_data(m2_index, :);
verify_trace(testCase, figure_handle, ...
    'HD-EEG VEOGL:M2', expected_time_hours, expected_hd_eog)

clinical_channel_names = {'E2:M1', 'E1:M2', 'E2:M2'};
signal_labels = {signalHeader_final.signal_labels};
for channel_i = 1:numel(clinical_channel_names)
    signal_index = strcmp( ...
        signal_labels, clinical_channel_names{channel_i});
    verify_trace(testCase, figure_handle, ...
        ['Clinical ' clinical_channel_names{channel_i}], ...
        expected_time_hours, signalCell_final{signal_index})
end

verifyEqual(testCase, signalCell_final, signalCell_before)
end

function testMissingClinicalChannelFails(testCase)
[final_eeg_data, aligned_eeg_channel_names, ...
    signalHeader_final, signalCell_final, edf_Fs] = make_fixture;
missing_index = strcmp( ...
    {signalHeader_final.signal_labels}, 'E2:M2');
signalHeader_final(missing_index) = [];
signalCell_final(missing_index) = [];

verifyError(testCase, @() sanity_check_EOG( ...
    final_eeg_data, aligned_eeg_channel_names, ...
    signalHeader_final, signalCell_final, edf_Fs), ...
    'sanity_check_EOG:MissingClinicalChannel')
end

function verify_trace( ...
    testCase, figure_handle, display_name, expected_x, expected_y)

line_handle = findall( ...
    figure_handle, 'Type', 'line', 'DisplayName', display_name);
verifyNumElements(testCase, line_handle, 1)
verifyEqual(testCase, line_handle.XData, expected_x, 'AbsTol', 1e-12)
verifyEqual(testCase, line_handle.YData, ...
    double(expected_y(:).'), 'AbsTol', 1e-12)

end

function [final_eeg_data, aligned_eeg_channel_names, ...
    signalHeader_final, signalCell_final, edf_Fs] = make_fixture

aligned_eeg_channel_names = {'Fp1', 'VEOGL', 'M2'};
final_eeg_data = [ ...
    20:25; ...
    10:15; ...
    1:6];
signal_labels = {'Noise', 'E1:M2', 'E2:M2', 'E2:M1'};
for channel_i = numel(signal_labels):-1:1
    signalHeader_final(channel_i).signal_labels = ...
        signal_labels{channel_i};
end
signalCell_final = { ...
    [91; 92], ...
    [31; 32; 33; 34; 35; 36], ...
    [41 42 43 44 45 46], ...
    [21; 22; 23; 24; 25; 26]};
edf_Fs = 2;

end
