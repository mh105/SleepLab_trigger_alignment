function tests = test_resample_eeg_segments
tests = functiontests(localfunctions);
end

function setupOnce(~)
addpath(fileparts(fileparts(mfilename('fullpath'))))
end

function testNoDriftUsesEdfScalpRate(testCase)
eeg_Fs = 500;
edf_Fs = 256;
edf_trigger_Fs = 128;
eeg_sample_span = 1000;
edf_trigger_sample_span = 256;
time_sec = (0:eeg_sample_span) / eeg_Fs;
eeg_segment_data = {single([ ...
    sin(2 * pi * 10 * time_sec); ...
    cos(2 * pi * 20 * time_sec)])};
matched_segments = make_segment_table( ...
    eeg_sample_span, edf_trigger_sample_span);
edf_input = make_edf_input( ...
    edf_Fs, edf_trigger_Fs, size(eeg_segment_data{1}, 1));

resampled = resample_eeg_segments( ...
    eeg_segment_data, matched_segments, edf_input);

verifySize(testCase, resampled, [1 1])
verifySize(testCase, resampled{1}, [2 513])
verifyClass(testCase, resampled{1}, 'single')
end

function testLinearDriftUsesEdfTimeAxis(testCase)
eeg_Fs = 500;
edf_Fs = 256;
edf_trigger_Fs = 128;
eeg_sample_span = 5000;
edf_trigger_sample_span = 1281;
time_sec = (0:eeg_sample_span) / eeg_Fs;
eeg_segment_data = {single(sin(2 * pi * 10 * time_sec))};
matched_segments = make_segment_table( ...
    eeg_sample_span, edf_trigger_sample_span);
edf_input = make_edf_input( ...
    edf_Fs, edf_trigger_Fs, size(eeg_segment_data{1}, 1));

resampled = resample_eeg_segments( ...
    eeg_segment_data, matched_segments, edf_input);

edf_duration_sec = edf_trigger_sample_span / edf_trigger_Fs;
effective_hd_eeg_Fs = eeg_sample_span / edf_duration_sec;
output_edf_time_sec = (0:2 * edf_trigger_sample_span) / edf_Fs;
expected_hd_eeg_time_sec = ...
    output_edf_time_sec * effective_hd_eeg_Fs / eeg_Fs;
expected_signal = sin(2 * pi * 10 * expected_hd_eeg_time_sec);
interior_index = 51:(numel(expected_signal) - 50);

verifySize(testCase, resampled{1}, [1 2563])
verifyEqual(testCase, output_edf_time_sec(end), ...
    edf_duration_sec, 'AbsTol', 1e-12)
verifyEqual(testCase, expected_hd_eeg_time_sec(end), 10, ...
    'AbsTol', 1e-12)
verifyEqual(testCase, ...
    double(resampled{1}(interior_index)), ...
    expected_signal(interior_index), 'AbsTol', 5e-3)
end

function testAntialiasingSuppressesAboveNyquistSignal(testCase)
eeg_Fs = 500;
edf_Fs = 256;
edf_trigger_Fs = 128;
eeg_sample_span = 2000;
edf_trigger_sample_span = 512;
time_sec = (0:eeg_sample_span) / eeg_Fs;
eeg_segment_data = {single(sin(2 * pi * 180 * time_sec))};
matched_segments = make_segment_table( ...
    eeg_sample_span, edf_trigger_sample_span);
edf_input = make_edf_input( ...
    edf_Fs, edf_trigger_Fs, size(eeg_segment_data{1}, 1));

resampled = resample_eeg_segments( ...
    eeg_segment_data, matched_segments, edf_input);

interior_signal = double(resampled{1}(101:end - 100));
verifyLessThan(testCase, rms(interior_signal), 1e-2)
end

function testEveryMatchedSegmentIsResampled(testCase)
edf_Fs = 256;
edf_trigger_Fs = 128;
eeg_sample_span = [1000; 1500];
edf_trigger_sample_span = [256; 383];
eeg_segment_data = { ...
    zeros(2, eeg_sample_span(1) + 1, 'single'); ...
    zeros(2, eeg_sample_span(2) + 1, 'single')};
matched_segments = make_segment_table( ...
    eeg_sample_span, edf_trigger_sample_span);
edf_input = make_edf_input( ...
    edf_Fs, edf_trigger_Fs, size(eeg_segment_data{1}, 1));

resampled = resample_eeg_segments( ...
    eeg_segment_data, matched_segments, edf_input);

verifySize(testCase, resampled, [2 1])
verifySize(testCase, resampled{1}, [2 513])
verifySize(testCase, resampled{2}, [2 767])
end

function testOptionalSanityPlots(testCase)
eeg_Fs = 500;
edf_Fs = 256;
edf_trigger_Fs = 128;
eeg_sample_span = 2000;
edf_trigger_sample_span = 512;
time_sec = (0:eeg_sample_span) / eeg_Fs;
channel_frequency = (1:10)';
eeg_segment_data = {single(sin( ...
    2 * pi * channel_frequency .* time_sec))};
matched_segments = make_segment_table( ...
    eeg_sample_span, edf_trigger_sample_span);
edf_input = make_edf_input(edf_Fs, edf_trigger_Fs, 10);

original_visibility = get(groot, 'defaultFigureVisible');
visibility_cleanup = onCleanup(@() set( ...
    groot, 'defaultFigureVisible', original_visibility));
set(groot, 'defaultFigureVisible', 'off')
figures_before = findall(groot, 'Type', 'figure');

resample_eeg_segments( ...
    eeg_segment_data, matched_segments, edf_input, true);

figures_after = findall(groot, 'Type', 'figure');
new_figures = setdiff(figures_after, figures_before);
figure_cleanup = onCleanup(@() delete(new_figures));
time_figure = findobj( ...
    new_figures, 'flat', 'Tag', 'resample_time_trace_comparison');
spectrum_figure = findobj( ...
    new_figures, 'flat', 'Tag', 'resample_welch_spectra');

verifyNumElements(testCase, new_figures, 2)
verifyNumElements(testCase, time_figure, 1)
verifyNumElements(testCase, spectrum_figure, 1)

trace_axes = findall(time_figure, 'Type', 'axes');
verifyNumElements(testCase, trace_axes, 10)
for axis_i = 1:numel(trace_axes)
    trace_lines = findall(trace_axes(axis_i), 'Type', 'line');
    verifyNumElements(testCase, trace_lines, 2)
    verifyEqual(testCase, sort([trace_lines.LineWidth]), [0.75 1.25])
end

spectrum_axes = findall( ...
    spectrum_figure, 'Type', 'axes', ...
    'Tag', 'resample_welch_spectrum_axes');
verifyNumElements(testCase, spectrum_axes, 1)
verifyNumElements(testCase, ...
    findall(spectrum_axes, 'Type', 'line'), 10)
verifyEqual(testCase, spectrum_axes.XLim, [0 128])
end

function matched_segments = make_segment_table( ...
    eeg_sample_span, edf_trigger_sample_span)

eeg_sample_span = eeg_sample_span(:);
edf_trigger_sample_span = edf_trigger_sample_span(:);
n_segments = numel(eeg_sample_span);
eeg_start_sample = (1:n_segments)' * 10 + 1;
eeg_end_sample = eeg_start_sample + eeg_sample_span;
edf_start_sample = (1:n_segments)' * 20 + 1;
edf_end_sample = edf_start_sample + edf_trigger_sample_span;
matched_segments = table( ...
    eeg_start_sample, eeg_end_sample, ...
    edf_start_sample, edf_end_sample);

end

function edf_input = make_edf_input(edf_Fs, edf_trigger_Fs, n_channels)

canonical_channel_names = [ ...
    "Fp1", "Fp2", "F3", "F4", "C3", ...
    "C4", "O1", "O2", "M1", "M2"];
edf_input.Fs = edf_Fs;
edf_input.trigger_Fs = edf_trigger_Fs;
edf_input.edf_eeg_channel_names = ...
    cellstr(canonical_channel_names(1:n_channels));

end
