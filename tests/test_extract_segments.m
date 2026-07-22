function tests = test_extract_segments
tests = functiontests(localfunctions);
end

function setupOnce(~)
project_path = fileparts(fileparts(mfilename('fullpath')));
addpath(project_path)
addpath(fullfile(project_path, 'helper_functions'))
end

function testAllMatchedChunksFormOneSegment(testCase)
[eeg, edf] = build_pair(complete_keep, complete_keep);
[result, eeg, edf] = match_triggers(eeg, edf);

report = extract_segments(result, eeg, edf);

verifyEqual(testCase, height(report), 1)
verifyEqual(testCase, ...
    string(report.Properties.VariableNames(1:4)), ...
    ["segment_index", "eeg_duration_sec", "edf_duration_sec", ...
    "edf_minus_eeg_sec"])
verifyFalse(testCase, ismember( ...
    "estimated_edf_trigger_Fs", string(report.Properties.VariableNames)))
verifyEqual(testCase, ...
    report{1, {'start_eeg_chunk', 'start_edf_chunk', 'start_interval', ...
    'end_eeg_chunk', 'end_edf_chunk', 'end_interval'}}, ...
    [1 1 1 5 5 49])
verifyEqual(testCase, report.eeg_start_sample, ...
    double(eeg.event_table.latency(1)))
verifyEqual(testCase, report.eeg_end_sample, ...
    result.eeg_terminal_anchor_latency)
verifyEqual(testCase, report.edf_start_sample, ...
    double(edf.event_table.latency(1)))
verifyEqual(testCase, report.edf_end_sample, ...
    result.edf_terminal_anchor_latency)
end

function testShortLossIsSplitAtCanonicalPrefixAndSuffix(testCase)
for affected_system = ["eeg", "edf"]
    if affected_system == "eeg"
        [eeg, edf] = build_pair(short_loss_keep, complete_keep);
    else
        [eeg, edf] = build_pair(complete_keep, short_loss_keep);
    end
    [result, eeg, edf] = match_triggers(eeg, edf);

    report = extract_segments(result, eeg, edf);

    verifyEqual(testCase, height(report), 2)
    verifyEqual(testCase, ...
        report{:, {'start_eeg_chunk', 'start_edf_chunk', ...
        'start_interval', 'end_eeg_chunk', 'end_edf_chunk', ...
        'end_interval'}}, ...
        [1 1 1 2 2 10; 2 2 14 5 5 49])

    loss = result.missing_periods(1, :);
    if affected_system == "eeg"
        verifyEqual(testCase, report.eeg_end_sample(1), ...
            loss.start_anchor_latency)
        verifyEqual(testCase, report.eeg_start_sample(2), ...
            loss.end_anchor_latency)
        verifyEqual(testCase, report.edf_end_sample(1), ...
            double(edf.event_table.latency(61)))
        verifyEqual(testCase, report.edf_start_sample(2), ...
            double(edf.event_table.latency(64)))
    else
        verifyEqual(testCase, report.edf_end_sample(1), ...
            loss.start_anchor_latency)
        verifyEqual(testCase, report.edf_start_sample(2), ...
            loss.end_anchor_latency)
        verifyEqual(testCase, report.eeg_end_sample(1), ...
            double(eeg.event_table.latency(61)))
        verifyEqual(testCase, report.eeg_start_sample(2), ...
            double(eeg.event_table.latency(64)))
    end
end
end

function testMissingBoundaryMapsSuffixToSkippedCleanChunk(testCase)
[eeg, edf] = build_pair(missing_boundary_keep, complete_keep);
[result, eeg, edf] = match_triggers(eeg, edf);

report = extract_segments(result, eeg, edf);

verifyEqual(testCase, height(report), 2)
verifyEqual(testCase, ...
    report{:, {'start_eeg_chunk', 'start_edf_chunk', 'start_interval', ...
    'end_eeg_chunk', 'end_edf_chunk', 'end_interval'}}, ...
    [1 1 1 2 2 49; 2 3 7 4 5 49])
verifyEqual(testCase, report.eeg_start_sample(2), ...
    result.missing_periods.end_anchor_latency)
verifyEqual(testCase, report.edf_start_sample(2), ...
    double(edf.event_table.latency(107)))
end

function testSharedTriggerGlitchStaysContinuous(testCase)
[eeg, edf] = build_pair(short_loss_keep, short_loss_keep);
[result, eeg, edf] = match_triggers(eeg, edf);

report = extract_segments(result, eeg, edf);

verifyEqual(testCase, height(report), 1)
verifyEqual(testCase, report.start_interval, 1)
verifyEqual(testCase, report.end_interval, 49)
end

function testSharedGlitchDoesNotRelockAnOpenLoss(testCase)
[eeg_keep, edf_keep] = open_loss_then_shared_glitch_keep;
[eeg, edf] = build_pair(eeg_keep, edf_keep);
[result, eeg, edf] = match_triggers(eeg, edf);

verifyEqual(testCase, result.comparison_history.outcome, ...
    ["match"; "eeg_data_loss"; "shared_trigger_glitch"; ...
    "match"; "match"; "same_last_trigger"])
verifyEqual(testCase, result.missing_periods.start_anchor_time_sec, 3058)
verifyEqual(testCase, result.missing_periods.end_anchor_time_sec, 5175)
report = extract_segments(result, eeg, edf);

verifyEqual(testCase, height(report), 2)
verifyEqual(testCase, ...
    report{:, {'start_eeg_chunk', 'start_edf_chunk', 'start_interval', ...
    'end_eeg_chunk', 'end_edf_chunk', 'end_interval'}}, ...
    [1 1 1 2 2 43; 4 4 1 6 6 49])
end

function testSharedGlitchDoesNotRelockAnOpenEdfLoss(testCase)
[eeg_keep, edf_keep] = open_loss_then_shared_glitch_keep;
[eeg, edf] = build_pair(edf_keep, eeg_keep);
[result, eeg, edf] = match_triggers(eeg, edf);

verifyEqual(testCase, result.comparison_history.outcome, ...
    ["match"; "edf_data_loss"; "shared_trigger_glitch"; ...
    "match"; "match"; "same_last_trigger"])
verifyEqual(testCase, result.missing_periods.start_anchor_time_sec, 3158)
verifyEqual(testCase, result.missing_periods.end_anchor_time_sec, 5275)
report = extract_segments(result, eeg, edf);

verifyEqual(testCase, height(report), 2)
verifyEqual(testCase, ...
    report{:, {'start_eeg_chunk', 'start_edf_chunk', 'start_interval', ...
    'end_eeg_chunk', 'end_edf_chunk', 'end_interval'}}, ...
    [1 1 1 2 2 43; 4 4 1 6 6 49])
end

function testSharedTerminalGlitchKeepsCanonicalIntervalNumber(testCase)
[eeg, edf] = build_pair(shared_terminal_glitch_keep, ...
    shared_terminal_glitch_keep);
[result, eeg, edf] = match_triggers(eeg, edf);

report = extract_segments(result, eeg, edf);

verifyEqual(testCase, height(report), 1)
verifyEqual(testCase, report.end_interval, 49)
end

function testDurationsUseElapsedSampleSpans(testCase)
[eeg, edf] = build_pair(complete_keep, complete_keep);
edf.event_table.latency(end) = edf.event_table.latency(end) - 1;
[result, eeg, edf] = match_triggers(eeg, edf); %#ok<ASGLU>

display_text = evalc( ...
    'report = extract_segments(result, eeg, edf);');

eeg_span = report.eeg_end_sample - report.eeg_start_sample;
edf_span = report.edf_end_sample - report.edf_start_sample;
expected_eeg_duration = eeg_span ./ eeg.Fs;
expected_edf_duration = edf_span ./ edf.trigger_Fs;
verifyEqual(testCase, report.eeg_duration_sec, ...
    expected_eeg_duration, 'AbsTol', 1e-12)
verifyEqual(testCase, report.edf_duration_sec, ...
    expected_edf_duration, 'AbsTol', 1e-12)
verifyEqual(testCase, report.edf_minus_eeg_sec, ...
    expected_edf_duration - expected_eeg_duration, 'AbsTol', 1e-12)
expected_eeg_duration_text = compose('%.5f', report.eeg_duration_sec);
expected_edf_duration_text = compose('%.5f', report.edf_duration_sec);
verifyTrue(testCase, contains( ...
    string(display_text), expected_eeg_duration_text))
verifyTrue(testCase, contains( ...
    string(display_text), expected_edf_duration_text))
verifyClass(testCase, report.eeg_duration_sec, 'double')
verifyClass(testCase, report.edf_duration_sec, 'double')
end

function testClockDriftMetricsAndPlotDefault(testCase)
[eeg, edf] = build_pair(complete_keep, complete_keep);
[result, eeg, edf] = match_triggers(eeg, edf);

figure_count_before = numel(findall(groot, 'Type', 'figure'));
report = extract_segments(result, eeg, edf);
figure_count_after = numel(findall(groot, 'Type', 'figure'));

verifyEqual(testCase, figure_count_after, figure_count_before)
verifyEqual(testCase, report.clock_drift_r_squared, 1)
verifyEqual(testCase, report.clock_drift_max_abs_residual_sec, 0, ...
    'AbsTol', 1e-10)
end

function testLinearClockDriftIsReportedForEverySegment(testCase)
[eeg, edf] = build_pair(short_loss_keep, complete_keep);
[result, eeg, edf] = match_triggers(eeg, edf);
edf = add_clock_drift(edf, 50);

report = extract_segments(result, eeg, edf);

verifyEqual(testCase, height(report), 2)
verifyGreaterThan(testCase, report.clock_drift_r_squared, 0.98)
verifyLessThanOrEqual(testCase, ...
    report.clock_drift_max_abs_residual_sec, ...
    result.interval_tolerance_sec)
end

function testPlotOverlaysCumulativeDifferenceBySegment(testCase)
[eeg, edf] = build_pair(short_loss_keep, complete_keep);
[result, eeg, edf] = match_triggers(eeg, edf);
edf = add_clock_drift(edf, 50);

original_visibility = get(groot, 'defaultFigureVisible');
visibility_cleanup = onCleanup(@() set( ...
    groot, 'defaultFigureVisible', original_visibility));
set(groot, 'defaultFigureVisible', 'off')
figure_count_before = numel(findall(groot, 'Type', 'figure'));

report = extract_segments(result, eeg, edf, true);
figure_handle = gcf;
figure_cleanup = onCleanup(@() close(figure_handle));

verifyEqual(testCase, ...
    numel(findall(groot, 'Type', 'figure')), figure_count_before + 1)
lines = findobj(figure_handle, 'Type', 'line');
verifyNumElements(testCase, lines, height(report))
verifyEqual(testCase, sort(string({lines.DisplayName})), ...
    ["segment index 1", "segment index 2"])
verifyTrue(testCase, all(string({lines.LineStyle}) == "-"))
verifyTrue(testCase, all(string({lines.Marker}) == "o"))
verifyTrue(testCase, all([lines.LineWidth] == 1))
axes_handle = findobj(figure_handle, 'Type', 'axes');
legend_handle = findobj(figure_handle, 'Type', 'legend');
verifyNumElements(testCase, axes_handle, 1)
verifyNumElements(testCase, legend_handle, 1)
verifyEqual(testCase, axes_handle.FontSize, 16)
verifyEqual(testCase, axes_handle.Title.FontSize, 24)
verifyEqual(testCase, legend_handle.FontSize, 20)
verifyEqual(testCase, string(axes_handle.XLabel.String), ...
    "Time within continuous segment (hr)")

for line_i = 1:numel(lines)
    segment_i = sscanf(lines(line_i).DisplayName, 'segment index %d');
    verifyEqual(testCase, lines(line_i).XData(1), 0, ...
        'AbsTol', 1e-12)
    verifyEqual(testCase, lines(line_i).XData(end), ...
        report.eeg_duration_sec(segment_i) / 3600, 'AbsTol', 1e-12)
    verifyGreaterThan(testCase, diff(lines(line_i).XData), 0)
    verifyEqual(testCase, lines(line_i).YData(1), 0, ...
        'AbsTol', 1e-12)
    verifyEqual(testCase, lines(line_i).YData(end), ...
        report.edf_minus_eeg_sec(segment_i), 'AbsTol', 1e-12)
end
end

function testNonlinearClockDriftFailsInLaterSegment(testCase)
[eeg, edf] = build_pair(short_loss_keep, complete_keep);
[result, eeg, edf] = match_triggers(eeg, edf);
report = extract_segments(result, eeg, edf);

segment_event_index = find( ...
    double(edf.event_table.latency) >= report.edf_start_sample(2) & ...
    double(edf.event_table.latency) <= report.edf_end_sample(2));
step_event_index = segment_event_index(ceil(numel(segment_event_index) / 2));
step_samples = round(0.1 * edf.trigger_Fs);
edf.event_table.latency(step_event_index:end) = ...
    edf.event_table.latency(step_event_index:end) + step_samples;

verifyError(testCase, ...
    @() extract_segments(result, eeg, edf), ...
    'extract_segments:NonlinearClockDrift')
end

function [eeg, edf] = build_pair(eeg_keep, edf_keep)

eeg.Fs = 500;
eeg.event_table = build_event_table(eeg.Fs, 0, eeg_keep);
edf.Fs = 256;
edf.trigger_Fs = 128;
edf.event_table = build_event_table(edf.trigger_Fs, 100, edf_keep);

end

function system = add_clock_drift(system, slope_ppm)

first_latency = double(system.event_table.latency(1));
relative_latency = double(system.event_table.latency) - first_latency;
system.event_table.latency = first_latency + round( ...
    relative_latency .* (1 + slope_ppm * 1e-6));

end

function event_table = build_event_table(Fs, start_time_sec, keep_by_cycle)

[canonical_type, canonical_interval_sec, canonical_time_sec] = ...
    canonical_template;
cycle_duration_sec = sum(canonical_interval_sec);
event_time_sec = zeros(0, 1);
event_type = strings(0, 1);

for cycle_i = 1:numel(keep_by_cycle)
    keep_index = keep_by_cycle{cycle_i};
    cycle_start_sec = start_time_sec + ...
        (cycle_i - 1) * cycle_duration_sec;
    event_time_sec = [event_time_sec; ...
        cycle_start_sec + canonical_time_sec(keep_index)]; %#ok<AGROW>
    event_type = [event_type; canonical_type(keep_index)]; %#ok<AGROW>
end

latency = round(event_time_sec .* Fs) + 1;
event_table = table(latency, event_type, ...
    'VariableNames', {'latency', 'type'});

end

function keep_by_cycle = complete_keep

keep_by_cycle = repmat({(1:50)'}, 5, 1);

end

function keep_by_cycle = short_loss_keep

keep_by_cycle = complete_keep;
keep_by_cycle{2} = setdiff((1:50)', (12:13)', 'stable');

end

function keep_by_cycle = missing_boundary_keep

keep_by_cycle = complete_keep;
keep_by_cycle{3} = (7:50)';

end

function [eeg_keep, edf_keep] = open_loss_then_shared_glitch_keep

eeg_keep = repmat({(1:50)'}, 6, 1);
edf_keep = eeg_keep;
eeg_keep{2} = (1:44)';
eeg_keep{3} = setdiff((1:50)', (12:13)', 'stable');
edf_keep{3} = eeg_keep{3};

end

function keep_by_cycle = shared_terminal_glitch_keep

keep_by_cycle = complete_keep;
keep_by_cycle{end} = setdiff((1:50)', (12:13)', 'stable');

end

function [type, interval_to_next_sec, relative_time_sec] = ...
    canonical_template

type = [repmat("64", 4, 1); repmat("63", 46, 1)];
interval_to_next_sec = (10:59)';
relative_time_sec = [0; cumsum(interval_to_next_sec(1:end - 1))];

end
