function tests = test_extract_canonical_cycle
tests = functiontests(localfunctions);
end

function setupOnce(~)
project_path = fileparts(fileparts(mfilename('fullpath')));
addpath(project_path)
addpath(fullfile(project_path, 'helper_functions'))
end

function testConsensusIgnoresDamagedFirstCycleAndMissingBoundary(testCase)
Fs = 1000;
interval_tolerance_sec = 2 / Fs;
cycle_start_sec = (0:60:360)';
has_boundary = [true; true; true; true; false; true; true];
missing_63 = repmat({[]}, numel(cycle_start_sec), 1);
missing_63{1} = [1, 3];

event_table = build_event_table( ...
    cycle_start_sec, has_boundary, missing_63, {}, Fs);
[canonical_cycle, repeat_count, chunk_report] = ...
    extract_canonical_cycle(event_table, Fs, interval_tolerance_sec);

verifyEqual(testCase, canonical_cycle.type, ...
    [repmat("64", 4, 1); repmat("63", 4, 1)])
verifyEqual(testCase, canonical_cycle.relative_time_sec, ...
    [-10; -9; -8; -7; 0; 10; 25; 40], 'AbsTol', 1 / Fs)
verifyEqual(testCase, canonical_cycle.interval_to_next_sec, ...
    [1; 1; 1; 7; 10; 15; 15; 10], 'AbsTol', 1 / Fs)
verifyEqual(testCase, repeat_count, 4)
verifyEqual(testCase, chunk_report.status, ...
    ["mismatch"; "match"; "match"; "ambiguous"; "match"; "match"])
verifyEqual(testCase, chunk_report.reason(4), "suspected_missing_boundary")
verifyEqual(testCase, chunk_report.estimated_cycle_count(4), 2)
verifyEqual(testCase, chunk_report.reason(end), "next_boundary_not_observed")
end

function testRandomlyMissing63TriggersDoNotDefineCanonicalCycle(testCase)
Fs = 1000;
interval_tolerance_sec = 2 / Fs;
cycle_start_sec = (0:60:360)';
has_boundary = true(size(cycle_start_sec));
missing_63 = repmat({[]}, numel(cycle_start_sec), 1);
missing_63{1} = 2;
missing_63{3} = 3;
missing_63{5} = 4;

event_table = build_event_table( ...
    cycle_start_sec, has_boundary, missing_63, {}, Fs);
[~, repeat_count, chunk_report] = ...
    extract_canonical_cycle(event_table, Fs, interval_tolerance_sec);

verifyEqual(testCase, repeat_count, 4)
verifyEqual(testCase, chunk_report.status, ...
    ["mismatch"; "match"; "mismatch"; "match"; ...
     "mismatch"; "match"; "match"])
end

function testIncompleteFinalCycleIsReportedSeparately(testCase)
Fs = 1000;
interval_tolerance_sec = 2 / Fs;
cycle_start_sec = (0:60:180)';
has_boundary = true(size(cycle_start_sec));
missing_63 = repmat({[]}, numel(cycle_start_sec), 1);
missing_63{end} = 4;

event_table = build_event_table( ...
    cycle_start_sec, has_boundary, missing_63, {}, Fs);
[~, repeat_count, chunk_report] = ...
    extract_canonical_cycle(event_table, Fs, interval_tolerance_sec);

verifyEqual(testCase, repeat_count, 3)
verifyEqual(testCase, chunk_report.status(end), "partial_end")
verifyEqual(testCase, chunk_report.reason(end), "count_or_type")
verifyEqual(testCase, chunk_report.start_time_sec, cycle_start_sec)
end

function testIntervalTolerance(testCase)
Fs = 1000;
interval_tolerance_sec = 2 / Fs;
cycle_start_sec = (0:60:420)';
has_boundary = true(size(cycle_start_sec));
missing_63 = repmat({[]}, numel(cycle_start_sec), 1);
body_shift_sec = repmat({zeros(4, 1)}, numel(cycle_start_sec), 1);
body_shift_sec{6}(3) = 2 / Fs;
body_shift_sec{7}(3) = 3 / Fs;

event_table = build_event_table( ...
    cycle_start_sec, has_boundary, missing_63, body_shift_sec, Fs);
[~, repeat_count, chunk_report] = ...
    extract_canonical_cycle(event_table, Fs, interval_tolerance_sec);

verifyEqual(testCase, chunk_report.status(6), "match")
verifyEqual(testCase, chunk_report.status(7), "mismatch")
verifyEqual(testCase, chunk_report.reason(7), "interval_timing")
verifyEqual(testCase, repeat_count, 7)
end

function testTiedCycleStructuresFailLoudly(testCase)
Fs = 1000;
interval_tolerance_sec = 2 / Fs;
cycle_start_sec = (0:60:360)';
has_boundary = true(size(cycle_start_sec));
missing_63 = repmat({[]}, numel(cycle_start_sec), 1);
body_shift_sec = repmat({zeros(4, 1)}, numel(cycle_start_sec), 1);
alternative_shift_sec = [0; 2; 4; 2];
body_shift_sec([2, 4, 6]) = {alternative_shift_sec};

event_table = build_event_table( ...
    cycle_start_sec, has_boundary, missing_63, body_shift_sec, Fs);

verifyError(testCase, ...
    @() extract_canonical_cycle( ...
        event_table, Fs, interval_tolerance_sec), ...
    'extract_canonical_cycle:AmbiguousCanonicalCycle')
end

function event_table = build_event_table( ...
    cycle_start_sec, has_boundary, missing_63, body_shift_sec, Fs)

n_cycles = numel(cycle_start_sec);
if isempty(body_shift_sec)
    body_shift_sec = repmat({zeros(4, 1)}, n_cycles, 1);
end

boundary_offset_sec = [0; 1; 2; 3];
body_offset_sec = [10; 20; 35; 50];
event_time_sec = zeros(0, 1);
trigger_type = strings(0, 1);

for cycle_i = 1:n_cycles
    if has_boundary(cycle_i)
        event_time_sec = [event_time_sec; ...
            cycle_start_sec(cycle_i) + boundary_offset_sec]; %#ok<AGROW>
        trigger_type = [trigger_type; repmat("64", 4, 1)]; %#ok<AGROW>
    end

    keep_63 = true(4, 1);
    keep_63(missing_63{cycle_i}) = false;
    shifted_body_offset_sec = body_offset_sec + body_shift_sec{cycle_i};
    event_time_sec = [event_time_sec; ...
        cycle_start_sec(cycle_i) + shifted_body_offset_sec(keep_63)]; %#ok<AGROW>
    trigger_type = [trigger_type; repmat("63", sum(keep_63), 1)]; %#ok<AGROW>
end

[event_time_sec, sort_index] = sort(event_time_sec);
trigger_type = trigger_type(sort_index);
latency = round(event_time_sec .* Fs) + 1;
event_table = table(latency, trigger_type, ...
    'VariableNames', {'latency', 'type'});

end
