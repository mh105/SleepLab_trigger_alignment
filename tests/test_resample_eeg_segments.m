function tests = test_resample_eeg_segments
tests = functiontests(localfunctions);
end

function setupOnce(~)
project_path = fileparts(fileparts(mfilename('fullpath')));
addpath(project_path)
addpath(fullfile(project_path, 'helper_functions'))
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
verifyClass(testCase, resampled{1}, 'double')
end

function testLinearDriftUsesEdfTimeAxis(testCase)
eeg_Fs = 500;
edf_Fs = 256;
edf_trigger_Fs = 128;
eeg_sample_span = 60000;
edf_trigger_sample_span = 15361;
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
interior_index = output_edf_time_sec >= 40 & output_edf_time_sec < 80;

verifySize(testCase, resampled{1}, [1 30723])
verifyEqual(testCase, output_edf_time_sec(end), ...
    edf_duration_sec, 'AbsTol', 1e-12)
verifyEqual(testCase, expected_hd_eeg_time_sec(end), 120, ...
    'AbsTol', 1e-12)
verifyEqual(testCase, ...
    double(resampled{1}(interior_index)), ...
    expected_signal(interior_index), 'AbsTol', 5e-4)
end

function testAntialiasingMeetsPassbandAndStopbandSpecifications(testCase)
eeg_Fs = 500;
edf_Fs = 256;
edf_trigger_Fs = 128;
duration_sec = 240;
eeg_sample_span = duration_sec * eeg_Fs - 1;
edf_trigger_sample_span = duration_sec * edf_trigger_Fs;
effective_eeg_Fs = eeg_sample_span / ...
    (edf_trigger_sample_span / edf_trigger_Fs);
time_sec = (0:eeg_sample_span) / effective_eeg_Fs;
eeg_segment_data = {single([ ...
    sin(2 * pi * 120 * time_sec); ...
    cos(2 * pi * 128 * time_sec); ...
    sin(2 * pi * 128.3 * time_sec); ...
    sin(2 * pi * 180 * time_sec)])};
matched_segments = make_segment_table( ...
    eeg_sample_span, edf_trigger_sample_span);
edf_input = make_edf_input( ...
    edf_Fs, edf_trigger_Fs, size(eeg_segment_data{1}, 1));

resampled = resample_eeg_segments( ...
    eeg_segment_data, matched_segments, edf_input);

output_time_sec = (0:(size(resampled{1}, 2) - 1)) / edf_Fs;
interior_index = output_time_sec >= 80 & output_time_sec < 160;
interior_time_sec = output_time_sec(interior_index);
passband_amplitude = sinusoid_amplitude( ...
    resampled{1}(1, interior_index), interior_time_sec, 120);
stopband_edge_amplitude = sqrt(mean( ...
    resampled{1}(2, interior_index) .^ 2));
stopband_128_3_Hz_amplitude = sqrt(2 * mean( ...
    resampled{1}(3, interior_index) .^ 2));
stopband_180_Hz_amplitude = sqrt(2 * mean( ...
    resampled{1}(4, interior_index) .^ 2));

verifyGreaterThanOrEqual(testCase, passband_amplitude, 0.999)
verifyLessThanOrEqual(testCase, passband_amplitude, 1.001)
verifyLessThanOrEqual(testCase, stopband_edge_amplitude, 1.2e-4)
verifyLessThanOrEqual(testCase, stopband_128_3_Hz_amplitude, 1.2e-4)
verifyLessThanOrEqual(testCase, stopband_180_Hz_amplitude, 1.2e-4)
end

function testHighpassMeetsStopbandAndPassbandSpecifications(testCase)
eeg_Fs = 500;
edf_Fs = 256;
edf_trigger_Fs = 128;
duration_sec = 240;
eeg_sample_span = duration_sec * eeg_Fs;
edf_trigger_sample_span = duration_sec * edf_trigger_Fs;
time_sec = (0:eeg_sample_span) / eeg_Fs;
eeg_segment_data = {single([ ...
    sin(2 * pi * 0.15 * time_sec); ...
    sin(2 * pi * 0.30 * time_sec); ...
    sin(2 * pi * 10 * time_sec)])};
matched_segments = make_segment_table( ...
    eeg_sample_span, edf_trigger_sample_span);
edf_input = make_edf_input( ...
    edf_Fs, edf_trigger_Fs, size(eeg_segment_data{1}, 1));

resampled = resample_eeg_segments( ...
    eeg_segment_data, matched_segments, edf_input);

output_time_sec = (0:(size(resampled{1}, 2) - 1)) / edf_Fs;
interior_index = output_time_sec >= 80 & output_time_sec < 160;
interior_time_sec = output_time_sec(interior_index);
stopband_amplitude = sinusoid_amplitude( ...
    resampled{1}(1, interior_index), interior_time_sec, 0.15);
passband_edge_amplitude = sinusoid_amplitude( ...
    resampled{1}(2, interior_index), interior_time_sec, 0.30);
ten_Hz_amplitude = sinusoid_amplitude( ...
    resampled{1}(3, interior_index), interior_time_sec, 10);
stopband_upper_bound = 1.05 * 10 ^ (-80 / 20);
passband_lower_bound = 10 ^ (-0.05 / 20);
passband_upper_bound = 10 ^ (0.05 / 20);

verifyLessThanOrEqual(testCase, stopband_amplitude, stopband_upper_bound)
verifyGreaterThanOrEqual( ...
    testCase, passband_edge_amplitude, passband_lower_bound)
verifyLessThanOrEqual( ...
    testCase, passband_edge_amplitude, passband_upper_bound)
verifyGreaterThanOrEqual(testCase, ten_Hz_amplitude, passband_lower_bound)
verifyLessThanOrEqual(testCase, ten_Hz_amplitude, passband_upper_bound)
end

function testSingleInputIsPromotedBeforeLongDurationResampling(testCase)
eeg_Fs = 500;
edf_Fs = 256;
edf_trigger_Fs = 128;
eeg_sample_span = 512000;
edf_trigger_sample_span = 131073;
time_sec = (0:eeg_sample_span) / eeg_Fs;
single_signal = single(sin(2 * pi * 80 * time_sec));
matched_segments = make_segment_table( ...
    eeg_sample_span, edf_trigger_sample_span);
edf_input = make_edf_input(edf_Fs, edf_trigger_Fs, 1);

resampled_single = resample_eeg_segments( ...
    {single_signal}, matched_segments, edf_input);
resampled_double = resample_eeg_segments( ...
    {double(single_signal)}, matched_segments, edf_input);

verifyClass(testCase, resampled_single{1}, 'double')
verifyClass(testCase, resampled_double{1}, 'double')
verifySize(testCase, resampled_single{1}, [1 262147])
verifyEqual(testCase, resampled_single{1}, resampled_double{1}, ...
    'AbsTol', 1e-12)
end

function testMeanCenteringRemovesLargeChannelOffsets(testCase)
eeg_Fs = 500;
edf_Fs = 256;
edf_trigger_Fs = 128;
duration_sec = 60;
eeg_sample_span = duration_sec * eeg_Fs;
edf_trigger_sample_span = duration_sec * edf_trigger_Fs;
time_sec = (0:eeg_sample_span) / eeg_Fs;
signal = sin(2 * pi * 10 * time_sec);
eeg_segment_data = {[signal; signal + 1e9; signal - 2e9]};
matched_segments = make_segment_table( ...
    eeg_sample_span, edf_trigger_sample_span);
edf_input = make_edf_input(edf_Fs, edf_trigger_Fs, 3);

resampled = resample_eeg_segments( ...
    eeg_segment_data, matched_segments, edf_input);

output_time_sec = (0:(size(resampled{1}, 2) - 1)) / edf_Fs;
interior_index = output_time_sec >= 20 & output_time_sec < 40;
reference_signal = resampled{1}(1, interior_index);

verifyLessThan(testCase, max(abs( ...
    resampled{1}(2, interior_index) - reference_signal)), 5e-7)
verifyLessThan(testCase, max(abs( ...
    resampled{1}(3, interior_index) - reference_signal)), 5e-7)
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
duration_sec = 32;
eeg_sample_span = duration_sec * eeg_Fs;
edf_trigger_sample_span = duration_sec * edf_trigger_Fs;
time_sec = (0:eeg_sample_span) / eeg_Fs;
channel_frequency = (1:11)';
eeg_segment_data = {single(sin( ...
    2 * pi * channel_frequency .* time_sec) + ...
    sin(2 * pi * 180 * time_sec))};
matched_segments = make_segment_table( ...
    eeg_sample_span, edf_trigger_sample_span);
edf_input = make_edf_input(edf_Fs, edf_trigger_Fs, 11);

original_visibility = get(groot, 'defaultFigureVisible');
visibility_cleanup = onCleanup(@() set( ...
    groot, 'defaultFigureVisible', original_visibility));
set(groot, 'defaultFigureVisible', 'off')
figures_before = findall(groot, 'Type', 'figure');

resampled = resample_eeg_segments( ...
    eeg_segment_data, matched_segments, edf_input, true);

verifySize(testCase, resampled{1}, [11 8193])

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
trace_start_sec = 1;
trace_end_sec = 31;
verifyEqual(testCase, trace_axes(1).XLim, ...
    [trace_start_sec trace_end_sec])
antialiased_display_name = ...
    'Mean-centered + high-pass + anti-alias-filtered input';
common_quarter_second = (4 * trace_start_sec):(4 * trace_end_sec);
input_index = (common_quarter_second - 4 * trace_start_sec) * ...
    (eeg_Fs / 4) + 1;
resampled_index = (common_quarter_second - 4 * trace_start_sec) * ...
    (edf_Fs / 4) + 1;
for axis_i = 1:numel(trace_axes)
    trace_lines = findall(trace_axes(axis_i), 'Type', 'line');
    verifyNumElements(testCase, trace_lines, 2)
    verifyEqual(testCase, sort([trace_lines.LineWidth]), [0.75 1.25])
    antialiased_input_line = findall( ...
        trace_axes(axis_i), 'Type', 'line', ...
        'DisplayName', antialiased_display_name);
    resampled_line = findall( ...
        trace_axes(axis_i), 'Type', 'line', ...
        'DisplayName', 'Resampled');
    verifyEqual(testCase, ...
        antialiased_input_line.XData(input_index), ...
        common_quarter_second / 4, 'AbsTol', 1e-12)
    verifyEqual(testCase, ...
        resampled_line.XData(resampled_index), ...
        common_quarter_second / 4, 'AbsTol', 1e-12)
    verifyEqual(testCase, ...
        antialiased_input_line.YData(input_index), ...
        resampled_line.YData(resampled_index), 'AbsTol', 1e-12)
end

antialiased_input_lines = findall( ...
    time_figure, 'Type', 'line', ...
    'DisplayName', antialiased_display_name);
verifyNumElements(testCase, antialiased_input_lines, 10)

spectrum_axes = findall( ...
    spectrum_figure, 'Type', 'axes', ...
    'Tag', 'resample_welch_spectrum_axes');
verifyNumElements(testCase, spectrum_axes, 1)
verifyNumElements(testCase, ...
    findall(spectrum_axes, 'Type', 'line'), 10)
verifyEmpty(testCase, findall( ...
    spectrum_axes, 'Type', 'line', 'DisplayName', 'VEOGL'))
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
    "C4", "O1", "O2", "M1", "M2", "VEOGL"];
edf_input.Fs = edf_Fs;
edf_input.trigger_Fs = edf_trigger_Fs;
edf_input.aligned_eeg_channel_names = ...
    cellstr(canonical_channel_names(1:n_channels));

end

function amplitude = sinusoid_amplitude(signal, time_sec, frequency_Hz)

amplitude = 2 / numel(signal) * abs(sum( ...
    signal .* exp(-1i * 2 * pi * frequency_Hz * time_sec)));

end
