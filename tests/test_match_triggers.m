function tests = test_match_triggers
tests = functiontests(localfunctions);
end

function setupOnce(~)
project_path = fileparts(fileparts(mfilename('fullpath')));
addpath(project_path)
addpath(fullfile(project_path, 'helper_functions'))
end

function testShortEegLossIsBracketed(testCase)
[eeg, edf, ~] = build_pair( ...
    short_loss_keep, complete_keep);

result = run_match(eeg, edf);

verifyEqual(testCase, result.matched_chunk_count, 3)
verifyEqual(testCase, result.initial_matched_chunk_count, 1)
verifyEqual(testCase, result.first_problem_chunk, 2)
verifyEqual(testCase, result.outcome, "eeg_data_loss")
verifyEqual(testCase, result.resolution_status, ...
    "resumed_same_offset")
verifyFalse(testCase, result.requires_relock)
verifyFalse(testCase, result.suspected_missing_boundary)
verifyTrue(testCase, result.whole_cycle_loss_cannot_be_excluded)
verifyEqual(testCase, result.missing_periods.system, "eeg")
verifyEqual(testCase, ...
    result.missing_periods.start_anchor_latency, 935001)
verifyEqual(testCase, ...
    result.missing_periods.end_anchor_latency, 966501)
verifyEqual(testCase, ...
    result.missing_periods.start_anchor_time_sec, 1870)
verifyEqual(testCase, ...
    result.missing_periods.end_anchor_time_sec, 1933)
verifyEqual(testCase, ...
    result.comparison_history{:, 1:2}, ...
    [1 1; 2 2; 3 3; 4 4; 5 5])
verifyTrue(testCase, result.terminal_chunk_deferred)
verifyTrue(testCase, result.terminal_chunk_handled)
end

function testLongEegLossFlagsMissingBoundary(testCase)
[eeg, edf, ~] = build_pair( ...
    missing_boundary_keep, complete_keep);

result = run_match(eeg, edf);

verifyEqual(testCase, result.outcome, "eeg_data_loss")
verifyTrue(testCase, result.suspected_missing_boundary)
verifyEqual(testCase, result.resolution_status, ...
    "resumed_after_boundary_skip")
verifyEqual(testCase, result.missing_periods.reason, ...
    "suspected_missing_boundary")
verifyEqual(testCase, ...
    result.missing_periods.start_anchor_latency, 1695501)
verifyEqual(testCase, ...
    result.missing_periods.end_anchor_latency, 1762501)
verifyEqual(testCase, ...
    result.comparison_history{:, 1:2}, [1 1; 2 2; 3 4; 4 5])
end

function testShortEdfLossMirrorsEegLoss(testCase)
[eeg, edf, ~] = build_pair( ...
    complete_keep, short_loss_keep);

result = run_match(eeg, edf);

verifyEqual(testCase, result.outcome, "edf_data_loss")
verifyEqual(testCase, result.missing_periods.system, "edf")
verifyEqual(testCase, ...
    result.missing_periods.start_anchor_latency, 252161)
verifyEqual(testCase, ...
    result.missing_periods.end_anchor_latency, 260225)
verifyEqual(testCase, ...
    result.comparison_history{:, 1:2}, ...
    [1 1; 2 2; 3 3; 4 4; 5 5])
end

function testLongEdfLossFlagsMissingBoundary(testCase)
[eeg, edf, ~] = build_pair( ...
    complete_keep, missing_boundary_keep);

result = run_match(eeg, edf);

verifyEqual(testCase, result.outcome, "edf_data_loss")
verifyTrue(testCase, result.suspected_missing_boundary)
verifyEqual(testCase, ...
    result.missing_periods.start_anchor_latency, 446849)
verifyEqual(testCase, ...
    result.missing_periods.end_anchor_latency, 464001)
verifyEqual(testCase, ...
    result.comparison_history{:, 1:2}, [1 1; 2 2; 4 3; 5 4])
end

function testSharedTriggerGlitchRemainsAligned(testCase)
[eeg, edf, ~] = build_pair( ...
    short_loss_keep, short_loss_keep);

result = run_match(eeg, edf);

verifyEqual(testCase, result.matched_chunk_count, 3)
verifyEqual(testCase, result.first_problem_chunk, 2)
verifyEqual(testCase, result.outcome, "shared_trigger_glitch")
verifyEqual(testCase, result.resolution_status, "resumed_same_offset")
verifyFalse(testCase, result.requires_relock)
verifyEqual(testCase, height(result.missing_periods), 0)
verifyEqual(testCase, ...
    result.comparison_history{:, 1:2}, ...
    [1 1; 2 2; 3 3; 4 4; 5 5])
end

function testSharedTriggerGlitchUsesTolerance(testCase)
[eeg, edf, ~] = build_pair( ...
    short_loss_keep, short_loss_keep);
shift_event_index = edf.chunk_report.start_event_index(2) + 20;

edf_at_tolerance = edf;
edf_at_tolerance.event_table.latency(shift_event_index) = ...
    edf_at_tolerance.event_table.latency(shift_event_index) + 2;
result = run_match(eeg, edf_at_tolerance);
verifyEqual(testCase, result.outcome, "shared_trigger_glitch")

edf_above_tolerance = edf;
edf_above_tolerance.event_table.latency(shift_event_index) = ...
    edf_above_tolerance.event_table.latency(shift_event_index) + 3;
result = run_match(eeg, edf_above_tolerance);
verifyEqual(testCase, result.outcome, "both_systems_unusable")
end

function testMatchingContinuesThroughSecondMismatch(testCase)
[eeg, edf, ~] = build_pair( ...
    six_cycle_short_loss_keep, six_cycle_late_short_loss_keep);

result = run_match(eeg, edf);

verifyEqual(testCase, result.comparison_history.outcome, ...
    ["match"; "eeg_data_loss"; "match"; "edf_data_loss"; ...
     "match"; "same_last_trigger"])
verifyEqual(testCase, ...
    result.comparison_history{:, 1:2}, ...
    [1 1; 2 2; 3 3; 4 4; 5 5; 6 6])
verifyEqual(testCase, result.missing_periods.system, ["eeg"; "edf"])
verifyEqual(testCase, height(result.missing_periods), 2)
verifyTrue(testCase, result.terminal_chunk_deferred)
end

function testCanonicalIntervalMismatchFailsLoudly(testCase)

[eeg, edf] = build_pair(complete_keep, complete_keep);
shifted_event_index = (26:50:height(edf.event_table))';
edf.event_table.latency(shifted_event_index) = ...
    edf.event_table.latency(shifted_event_index) + 3;

verifyError(testCase, ...
    @() match_triggers(eeg, edf), ...
    'validate_canonical_cycles:IntervalMismatch')

end

function testCanonicalCycleWithWrongTriggerCountFailsLoudly(testCase)

[eeg, edf] = build_pair(forty_nine_trigger_keep, complete_keep);

verifyError(testCase, ...
    @() match_triggers(eeg, edf), ...
    'validate_canonical_cycles:UnexpectedTriggerCount')

end

function testExactlyFiftyNoncanonicalTriggersStopForReview(testCase)
[eeg, edf, tolerance_sec] = build_pair(complete_keep, complete_keep);
cycle_duration_sec = sum(eeg.canonical_cycle.interval_to_next_sec);
shift_start = eeg.chunk_report.start_event_index(2) + 20;
eeg.event_table.latency(shift_start:end) = ...
    eeg.event_table.latency(shift_start:end) + ...
    cycle_duration_sec * eeg.Fs;
[eeg.canonical_cycle, ~, eeg.chunk_report] = extract_canonical_cycle( ...
    eeg.event_table, eeg.Fs, tolerance_sec);

result = run_match(eeg, edf);

verifyEqual(testCase, result.outcome, "eeg_data_loss")
verifyEqual(testCase, result.resolution_status, ...
    "unsupported_cycle_count_ambiguity")
verifyEqual(testCase, result.stopped_reason, ...
    "unsupported_cycle_count_ambiguity")
verifyTrue(testCase, result.requires_relock)
verifyEqual(testCase, ...
    result.comparison_history{:, 1:2}, [1 1; 2 2])
verifyTrue(testCase, ...
    all(isnan(result.comparison_history{2, 7:8})))
end

function testDivergentDamageLeavesOpenPeriods(testCase)
[eeg, edf, ~] = build_pair( ...
    short_loss_keep, different_short_loss_keep);

result = run_match(eeg, edf);

verifyEqual(testCase, result.outcome, "both_systems_unusable")
verifyEqual(testCase, result.resolution_status, ...
    "requires_next_shared_chunk")
verifyTrue(testCase, result.requires_relock)
verifyEqual(testCase, result.missing_periods.system, ["eeg"; "edf"])
verifyEqual(testCase, ...
    result.missing_periods.start_anchor_latency, [935001; 252161])
verifyTrue(testCase, ...
    all(isnan(result.missing_periods.end_anchor_latency)))
end

function testAbortedEdfStartupAlignsAtRestartBoundary(testCase)
[eeg, edf, ~] = build_pair( ...
    complete_keep, edf_aborted_startup_keep);
verifyEqual(testCase, ...
    diff(double(edf.event_table.latency(1:10))) ./ edf.trigger_Fs, ...
    eeg.canonical_cycle.interval_to_next_sec(1:9))
verifyEqual(testCase, ...
    diff(double(edf.event_table.latency(11:61))) ./ edf.trigger_Fs, ...
    eeg.canonical_cycle.interval_to_next_sec)

[result, eeg_output, edf_output] = ...
    run_match(eeg, edf);

verifyEqual(testCase, result.initial_eeg_chunk_index, 1)
verifyEqual(testCase, result.initial_edf_chunk_index, 2)
verifyTrue(testCase, result.edf_leading_restart_inferred)
verifyTrue(testCase, result.initial_cycle_offset_uncertain)
verifyEqual(testCase, result.initial_alignment_reason, ...
    "edf_restart_at_t1_boundary")
verifyEqual(testCase, ...
    result.initial_matching_prefix_interval_count, 9)
verifyEqual(testCase, ...
    result.initial_matching_suffix_interval_count, 0)
verifyEqual(testCase, result.edf_pre_alignment_event_count, 10)
verifyEqual(testCase, result.eeg_initial_anchor_event_index, 1)
verifyEqual(testCase, result.edf_initial_anchor_event_index, 11)
verifyEqual(testCase, find(eeg_output.event_table.is_pre_alignment), ...
    zeros(0, 1))
verifyEqual(testCase, find(edf_output.event_table.is_pre_alignment), (1:10)')
verifyEqual(testCase, ...
    find(eeg_output.event_table.is_initial_alignment_anchor), 1)
verifyEqual(testCase, ...
    find(edf_output.event_table.is_initial_alignment_anchor), 11)
verifyEqual(testCase, result.comparison_history{:, 1:2}, ...
    [1 2; 2 3; 3 4; 4 5; 5 6])
verifyEqual(testCase, result.matched_chunk_count, 4)
verifyEqual(testCase, result.initial_matched_chunk_count, 4)
verifyTrue(testCase, isnan(result.first_problem_chunk))
verifyEqual(testCase, height(result.missing_periods), 0)
end

function testBracketedFirstEdfLossKeepsFirstChunkAlignment(testCase)
[eeg, edf, tolerance_sec] = build_pair( ...
    six_complete_keep, first_chunk_short_loss_keep);
verifyEqual(testCase, ...
    diff(double(edf.event_table.latency(1:11))) ./ edf.trigger_Fs, ...
    eeg.canonical_cycle.interval_to_next_sec(1:10))
verifyEqual(testCase, ...
    diff(double(edf.event_table.latency(12:49))) ./ edf.trigger_Fs, ...
    eeg.canonical_cycle.interval_to_next_sec(14:50))
verifyGreaterThan(testCase, abs( ...
    (double(edf.event_table.latency(12)) - ...
     double(edf.event_table.latency(11))) ./ edf.trigger_Fs - ...
    eeg.canonical_cycle.interval_to_next_sec(11)), tolerance_sec)

[result, eeg_output, edf_output] = ...
    run_match(eeg, edf);

verifyEqual(testCase, result.initial_edf_chunk_index, 1)
verifyFalse(testCase, result.edf_leading_restart_inferred)
verifyTrue(testCase, result.initial_cycle_offset_uncertain)
verifyEqual(testCase, result.initial_alignment_reason, ...
    "edf_first_chunk_bracketed_loss")
verifyEqual(testCase, ...
    result.initial_matching_prefix_interval_count, 10)
verifyEqual(testCase, ...
    result.initial_matching_suffix_interval_count, 37)
verifyEqual(testCase, find(eeg_output.event_table.is_pre_alignment), ...
    zeros(0, 1))
verifyEqual(testCase, find(edf_output.event_table.is_pre_alignment), ...
    zeros(0, 1))
verifyEqual(testCase, result.comparison_history{:, 1:2}, ...
    [1 1; 2 2; 3 3; 4 4; 5 5; 6 6])
verifyEqual(testCase, result.comparison_history.outcome(1), ...
    "edf_data_loss")
verifyEqual(testCase, ...
    result.missing_periods.start_anchor_event_index, 11)
verifyEqual(testCase, ...
    result.missing_periods.end_anchor_event_index, 12)
verifyEqual(testCase, result.missing_periods.eeg_chunk_index, 1)
verifyEqual(testCase, result.missing_periods.edf_chunk_index, 1)
end

function testFirstEdfMissingBoundaryUsesLongLossHandling(testCase)
[eeg, edf, ~] = build_pair( ...
    six_complete_keep, first_chunk_missing_boundary_keep);
verifyEqual(testCase, ...
    diff(double(edf.event_table.latency(1:50))) ./ edf.trigger_Fs, ...
    eeg.canonical_cycle.interval_to_next_sec(1:49))
verifyEqual(testCase, ...
    diff(double(edf.event_table.latency(51:95))) ./ edf.trigger_Fs, ...
    eeg.canonical_cycle.interval_to_next_sec(7:50))

[result, eeg_output, edf_output] = ...
    run_match(eeg, edf);

verifyEqual(testCase, result.initial_edf_chunk_index, 1)
verifyFalse(testCase, result.edf_leading_restart_inferred)
verifyEqual(testCase, result.initial_alignment_reason, ...
    "edf_first_chunk_missing_boundary")
verifyEqual(testCase, find(eeg_output.event_table.is_pre_alignment), ...
    zeros(0, 1))
verifyEqual(testCase, find(edf_output.event_table.is_pre_alignment), ...
    zeros(0, 1))
verifyEqual(testCase, result.outcome, "edf_data_loss")
verifyTrue(testCase, result.suspected_missing_boundary)
verifyEqual(testCase, result.resolution_status, ...
    "resumed_after_boundary_skip")
verifyEqual(testCase, result.comparison_history{:, 1:2}, ...
    [1 1; 3 2; 4 3; 5 4; 6 5])
verifyEqual(testCase, ...
    result.missing_periods.start_anchor_event_index, 50)
verifyEqual(testCase, ...
    result.missing_periods.end_anchor_event_index, 51)
end

function testSavedRecordingDefersFinalPartialChunks(testCase)
fixture_path = fullfile( ...
    fileparts(mfilename('fullpath')), ...
    'sas_023_trigger_event_tables.mat');
assumeTrue(testCase, isfile(fixture_path), ...
    'The local trigger-event fixture is not available.')

fixture = load(fixture_path);
eeg_input.event_table = fixture.eeg_event_table;
eeg_input.Fs = fixture.eeg_Fs;
edf_input.event_table = fixture.edf_event_table;
edf_input.trigger_Fs = fixture.edf_trigger_Fs;

[result, eeg_output, edf_output] = match_triggers(eeg_input, edf_input);

verifyEqual(testCase, result.matched_chunk_count, 10)
verifyTrue(testCase, isnan(result.first_problem_chunk))
verifyEqual(testCase, result.outcome, "all_nonterminal_chunks_match")
verifyTrue(testCase, result.terminal_chunk_deferred)
verifyTrue(testCase, result.terminal_chunk_handled)
verifyEqual(testCase, result.terminal_relation, "eeg_shorter")
verifyTrue(testCase, result.eeg_zero_padding_required)
verifyEqual(testCase, result.stopped_reason, "terminal_region_identified")
verifyEqual(testCase, height(result.missing_periods), 0)
verifyEqual(testCase, height(result.comparison_history), 11)
verifyEqual(testCase, result.interval_tolerance_sec, ...
    2 / min([fixture.eeg_Fs, fixture.edf_trigger_Fs]))
verifyTrue(testCase, istable(eeg_output.canonical_cycle))
verifyTrue(testCase, istable(edf_output.canonical_cycle))
verifyTrue(testCase, isfield(eeg_output, 'canonical_repeat_count'))
verifyTrue(testCase, isfield(edf_output, 'canonical_repeat_count'))
verifyTrue(testCase, istable(eeg_output.chunk_report))
verifyTrue(testCase, istable(edf_output.chunk_report))
end

function testEegShorterTerminalRegionMarksPaddingAnchor(testCase)
[eeg, edf, ~] = build_pair( ...
    partial_final_keep(30), partial_final_keep(45));

[result, eeg_output, edf_output] = ...
    run_match(eeg, edf);

verifyEqual(testCase, result.terminal_relation, "eeg_shorter")
verifyEqual(testCase, result.terminal_later_action, "zero_pad_eeg")
verifyTrue(testCase, result.eeg_zero_padding_required)
verifyEqual(testCase, result.eeg_terminal_anchor_event_index, 230)
verifyEqual(testCase, result.edf_terminal_anchor_event_index, 230)
verifyEqual(testCase, result.terminal_common_trigger_count, 30)
verifyEqual(testCase, result.eeg_terminal_anchor_latency, ...
    double(eeg.event_table.latency(230)))
verifyEqual(testCase, result.edf_terminal_anchor_latency, ...
    double(edf.event_table.latency(230)))
verifyEqual(testCase, find(eeg_output.event_table.is_terminal), (201:230)')
verifyEqual(testCase, find(edf_output.event_table.is_terminal), (201:245)')
verifyEqual(testCase, ...
    find(eeg_output.event_table.is_terminal_alignment_anchor), 230)
verifyEqual(testCase, ...
    find(edf_output.event_table.is_terminal_alignment_anchor), 230)
verifyEqual(testCase, result.comparison_history.outcome(end), ...
    "eeg_shorter")
verifyEqual(testCase, result.comparison_history{end, 1:2}, [5 5])
verifyTrue(testCase, all(isnan(result.comparison_history{end, 7:8})))
verifyTrue(testCase, isnan(result.first_problem_chunk))
verifyFalse(testCase, result.requires_relock)
verifyEqual(testCase, height(result.missing_periods), 0)
verifyTrue(testCase, result.terminal_chunk_handled)
verifyEqual(testCase, result.stopped_reason, "terminal_region_identified")
end

function testEegLongerTerminalRegionNeedsNoPadding(testCase)
[eeg, edf, ~] = build_pair( ...
    partial_final_keep(45), partial_final_keep(30));

[result, eeg_output, edf_output] = ...
    run_match(eeg, edf);

verifyEqual(testCase, result.terminal_relation, "eeg_longer")
verifyEqual(testCase, result.terminal_later_action, ...
    "match_edf_length_without_padding")
verifyFalse(testCase, result.eeg_zero_padding_required)
verifyEqual(testCase, result.eeg_terminal_anchor_event_index, 230)
verifyEqual(testCase, result.edf_terminal_anchor_event_index, 230)
verifyEqual(testCase, result.terminal_common_trigger_count, 30)
verifyEqual(testCase, result.eeg_terminal_anchor_latency, ...
    double(eeg.event_table.latency(230)))
verifyEqual(testCase, result.edf_terminal_anchor_latency, ...
    double(edf.event_table.latency(230)))
verifyEqual(testCase, find(eeg_output.event_table.is_terminal), (201:245)')
verifyEqual(testCase, find(edf_output.event_table.is_terminal), (201:230)')
verifyEqual(testCase, ...
    find(eeg_output.event_table.is_terminal_alignment_anchor), 230)
verifyEqual(testCase, ...
    find(edf_output.event_table.is_terminal_alignment_anchor), 230)
verifyEqual(testCase, result.comparison_history.outcome(end), ...
    "eeg_longer")
verifyEqual(testCase, result.comparison_history.resolution_status(end), ...
    "terminal_anchor_identified")
verifyTrue(testCase, all(isnan(result.comparison_history{end, 7:8})))
end

function testEegTerminalMakesLaterEdfChunksTerminal(testCase)
[eeg, edf, ~] = build_pair( ...
    complete_keep, continued_after_boundary_keep);
verifyFalse(testCase, eeg.chunk_report.has_next_boundary(5))
verifyTrue(testCase, edf.chunk_report.has_next_boundary(5))

[result, eeg_output, edf_output] = ...
    run_match(eeg, edf);

verifyEqual(testCase, result.terminal_relation, "eeg_shorter")
verifyEqual(testCase, result.eeg_terminal_chunk_indices, 5)
verifyEqual(testCase, result.edf_terminal_chunk_indices, [5 6])
verifyEqual(testCase, result.eeg_terminal_anchor_event_index, 250)
verifyEqual(testCase, result.edf_terminal_anchor_event_index, 250)
verifyEqual(testCase, result.terminal_common_trigger_count, 50)
verifyEqual(testCase, result.terminal_later_action, "zero_pad_eeg")
verifyTrue(testCase, result.eeg_zero_padding_required)
verifyEqual(testCase, find(eeg_output.event_table.is_terminal), (201:250)')
verifyEqual(testCase, find(edf_output.event_table.is_terminal), (201:260)')
verifyEqual(testCase, ...
    find(eeg_output.event_table.is_terminal_alignment_anchor), 250)
verifyEqual(testCase, ...
    find(edf_output.event_table.is_terminal_alignment_anchor), 250)
end

function testEdfTerminalMakesLaterEegChunksTerminal(testCase)
[eeg, edf, ~] = build_pair( ...
    continued_after_boundary_keep, complete_keep);
verifyTrue(testCase, eeg.chunk_report.has_next_boundary(5))
verifyFalse(testCase, edf.chunk_report.has_next_boundary(5))

[result, eeg_output, edf_output] = ...
    run_match(eeg, edf);

verifyEqual(testCase, result.terminal_relation, "eeg_longer")
verifyEqual(testCase, result.eeg_terminal_chunk_indices, [5 6])
verifyEqual(testCase, result.edf_terminal_chunk_indices, 5)
verifyEqual(testCase, result.eeg_terminal_anchor_event_index, 250)
verifyEqual(testCase, result.edf_terminal_anchor_event_index, 250)
verifyEqual(testCase, result.terminal_common_trigger_count, 50)
verifyEqual(testCase, result.terminal_later_action, ...
    "match_edf_length_without_padding")
verifyFalse(testCase, result.eeg_zero_padding_required)
verifyEqual(testCase, find(eeg_output.event_table.is_terminal), (201:260)')
verifyEqual(testCase, find(edf_output.event_table.is_terminal), (201:250)')
verifyEqual(testCase, ...
    find(eeg_output.event_table.is_terminal_alignment_anchor), 250)
verifyEqual(testCase, ...
    find(edf_output.event_table.is_terminal_alignment_anchor), 250)
end

function testTerminalAnchorsUseIndependentEventIndices(testCase)
[eeg, edf, ~] = build_pair( ...
    short_loss_partial_final_keep, partial_final_keep(45));

[result, eeg_output, edf_output] = ...
    run_match(eeg, edf);

verifyEqual(testCase, result.eeg_terminal_anchor_event_index, 228)
verifyEqual(testCase, result.edf_terminal_anchor_event_index, 230)
verifyEqual(testCase, ...
    find(eeg_output.event_table.is_terminal_alignment_anchor), 228)
verifyEqual(testCase, ...
    find(edf_output.event_table.is_terminal_alignment_anchor), 230)
end

function testTerminalComparisonUsesTolerance(testCase)
[eeg, edf, ~] = build_pair( ...
    partial_final_keep(30), partial_final_keep(30));
shift_event_index = 220;

edf_at_tolerance = edf;
edf_at_tolerance.event_table.latency(shift_event_index) = ...
    edf_at_tolerance.event_table.latency(shift_event_index) + 2;
result = run_match(eeg, edf_at_tolerance);
verifyEqual(testCase, result.terminal_relation, "same_last_trigger")

edf_above_tolerance = edf;
edf_above_tolerance.event_table.latency(shift_event_index) = ...
    edf_above_tolerance.event_table.latency(shift_event_index) + 3;
verifyError(testCase, @() run_match(eeg, edf_above_tolerance), ...
    'match_triggers:TerminalCorrespondenceMismatch')
end

function testTerminalMismatchFailsLoudly(testCase)
[eeg, edf, ~] = build_pair( ...
    partial_final_keep(30), partial_final_keep(45));
eeg.event_table.latency(220) = eeg.event_table.latency(220) + 100;

verifyError(testCase, @() run_match(eeg, edf), ...
    'match_triggers:TerminalCorrespondenceMismatch')
end

function testTerminalRequiresImmediatelyPrecedingLock(testCase)
[eeg, edf, ~] = build_pair(complete_keep, late_short_loss_keep);

verifyError(testCase, @() run_match(eeg, edf), ...
    'match_triggers:TerminalAlignmentNotLocked')
end

function testBoundarySkipCannotBypassTerminalRegion(testCase)
[eeg, edf, ~] = build_pair( ...
    late_missing_boundary_keep, four_complete_keep);

verifyError(testCase, @() run_match(eeg, edf), ...
    'match_triggers:TerminalRegionSkipped')
end

function testEqualTerminalRegionsReportSameLastTrigger(testCase)
[eeg, edf, ~] = build_pair( ...
    partial_final_keep(30), partial_final_keep(30));

result = run_match(eeg, edf);

verifyEqual(testCase, result.outcome, "all_nonterminal_chunks_match")
verifyEqual(testCase, result.resolution_status, ...
    "terminal_anchor_identified")
verifyEqual(testCase, result.terminal_relation, "same_last_trigger")
verifyEqual(testCase, result.terminal_later_action, ...
    "undetermined_from_trigger_tables")
verifyTrue(testCase, isnan(result.eeg_zero_padding_required))
verifyEqual(testCase, result.eeg_terminal_anchor_event_index, 230)
verifyEqual(testCase, result.edf_terminal_anchor_event_index, 230)
verifyEqual(testCase, result.terminal_common_trigger_count, 30)
end

function testMissingRequiredInputFieldFailsLoudly(testCase)
[eeg, edf, ~] = build_pair(complete_keep, complete_keep);
edf = rmfield(edf, 'trigger_Fs');

verifyError(testCase, @() run_match(eeg, edf), ...
    '')
end

function testExistingAlignmentFlagsAreReset(testCase)
[eeg, edf, ~] = build_pair(complete_keep, complete_keep);
flag_names = [ ...
    "is_pre_alignment", "is_initial_alignment_anchor", ...
    "is_terminal", "is_terminal_alignment_anchor"];
for flag_name = flag_names
    eeg.event_table.(flag_name) = true(height(eeg.event_table), 1);
    edf.event_table.(flag_name) = true(height(edf.event_table), 1);
end

[~, eeg_output, edf_output] = run_match(eeg, edf);

verifyEmpty(testCase, find(eeg_output.event_table.is_pre_alignment))
verifyEmpty(testCase, find(edf_output.event_table.is_pre_alignment))
verifyEqual(testCase, ...
    find(eeg_output.event_table.is_initial_alignment_anchor), 1)
verifyEqual(testCase, ...
    find(edf_output.event_table.is_initial_alignment_anchor), 1)
verifyEqual(testCase, ...
    find(eeg_output.event_table.is_terminal), (201:250)')
verifyEqual(testCase, ...
    find(edf_output.event_table.is_terminal), (201:250)')
verifyEqual(testCase, ...
    find(eeg_output.event_table.is_terminal_alignment_anchor), 250)
verifyEqual(testCase, ...
    find(edf_output.event_table.is_terminal_alignment_anchor), 250)
end

function testOptionalAlignmentPlotShowsLossAndZeroPadding(testCase)
[eeg, edf, ~] = build_pair( ...
    short_loss_partial_final_keep, partial_final_keep(45));
eeg.dur_hr = 2.5;
edf.dur_hr = 2.7;
[visibility_cleanup, figure_cleanup] = prepare_hidden_alignment_figure; %#ok<ASGLU>

[result, eeg_output, edf_output] = match_triggers(eeg, edf, true);

figure_handle = findobj(groot, ...
    'Type', 'figure', 'Tag', 'match_trigger_alignment');
verifyNumElements(testCase, figure_handle, 1)
ax_original = findobj(figure_handle, 'Tag', 'original_eeg_timeline');
ax_aligned = findobj(figure_handle, 'Tag', 'aligned_eeg_timeline');
ax_edf = findobj(figure_handle, 'Tag', 'edf_timeline');
verifyNumElements(testCase, [ax_original; ax_aligned; ax_edf], 3)

original_match = find_chunk_trace(ax_original, 1);
aligned_match = find_chunk_trace(ax_aligned, 1);
edf_match = find_chunk_trace(ax_edf, 1);
verifyNumElements(testCase, original_match, 1)
verifyNumElements(testCase, aligned_match, 1)
verifyNumElements(testCase, edf_match, 1)
expected_eeg_shift_hr = 100 ./ 3600;
verifyEqual(testCase, original_match.XData(1), 0, 'AbsTol', 1e-12)
verifyEqual(testCase, edf_match.XData(1), 100 ./ 3600, 'AbsTol', 1e-12)
verifyEqual(testCase, ...
    aligned_match.XData - original_match.XData, ...
    repmat(expected_eeg_shift_hr, size(original_match.XData)), ...
    'AbsTol', 1e-12)
initial_padding_bars = findall( ...
    ax_aligned, 'Tag', 'initial_zero_padding');
verifyNumElements(testCase, initial_padding_bars, 1)
verifyEqual(testCase, initial_padding_bars.Color, [0.6, 0.6, 0.6])
initial_padding_x = ...
    initial_padding_bars.XData(isfinite(initial_padding_bars.XData));
verifyEqual(testCase, min(initial_padding_x), 0, 'AbsTol', 1e-12)
verifyEqual(testCase, max(initial_padding_x), expected_eeg_shift_hr, ...
    'AbsTol', 1e-12)

eeg_match_rows = ( ...
    eeg_output.chunk_report.start_event_index(1): ...
    eeg_output.chunk_report.end_event_index(1))';
expected_eeg_type = ...
    str2double(string(eeg_output.event_table.type(eeg_match_rows)))';
verifyEqual(testCase, original_match.YData, expected_eeg_type)
verifyEqual(testCase, original_match.Color, edf_match.Color)
verifyEqual(testCase, original_match.LineStyle, '-')
verifyEqual(testCase, original_match.Marker, 'o')
original_loss = find_chunk_trace(ax_original, 2);
edf_loss = find_chunk_trace(ax_edf, 2);
verifyNumElements(testCase, original_loss, 1)
verifyNumElements(testCase, edf_loss, 1)
verifyEqual(testCase, original_loss.Color, zeros(1, 3))
verifyEqual(testCase, edf_loss.Color, zeros(1, 3))

recording_extent = findall(ax_edf, 'Tag', 'recording_extent');
verifyNumElements(testCase, recording_extent, 1)
verifyClass(testCase, recording_extent, 'matlab.graphics.primitive.Patch')
verifyEqual(testCase, recording_extent.FaceColor, [0.94, 0.94, 0.94])
verifyEqual(testCase, min(recording_extent.XData), 0)
verifyEqual(testCase, max(recording_extent.XData), edf.dur_hr)

original_unsafe_bars = findall(ax_original, 'Tag', 'unsafe_interval');
verifyNumElements(testCase, original_unsafe_bars, 1)
verifyNumElements(testCase, ...
    findall(ax_aligned, 'Tag', 'unsafe_interval'), 1)
verifyEmpty(testCase, findall(ax_edf, 'Tag', 'unsafe_interval'))
unsafe_x = original_unsafe_bars.XData(isfinite(original_unsafe_bars.XData));
unsafe_y = original_unsafe_bars.YData(isfinite(original_unsafe_bars.YData));
expected_unsafe_start_hr = ( ...
    result.missing_periods.start_anchor_latency(1) - 1) ./ eeg.Fs ./ 3600;
expected_unsafe_end_hr = ( ...
    result.missing_periods.end_anchor_latency(1) - 1) ./ eeg.Fs ./ 3600;
verifyEqual(testCase, min(unsafe_x), expected_unsafe_start_hr, ...
    'AbsTol', 1e-12)
verifyEqual(testCase, max(unsafe_x), expected_unsafe_end_hr, ...
    'AbsTol', 1e-12)
verifyEqual(testCase, min(unsafe_y), 62.6, 'AbsTol', 1e-12)
verifyEqual(testCase, max(unsafe_y), 64.4, 'AbsTol', 1e-12)
padding_bars = findall(ax_aligned, 'Tag', 'terminal_zero_padding');
edf_terminal_trace = find_chunk_trace( ...
    ax_edf, result.edf_terminal_chunk_indices(1));
verifyNumElements(testCase, padding_bars, 1)
verifyNumElements(testCase, edf_terminal_trace, 1)
verifyEqual(testCase, padding_bars.Color, edf_terminal_trace.Color)
verifyEmpty(testCase, findall(ax_edf, 'Tag', 'terminal_edf_tail'))
verifyEmpty(testCase, findall(ax_aligned, 'Tag', 'terminal_drop'))
end

function testOptionalAlignmentPlotShowsTerminalDrop(testCase)
[eeg, edf, ~] = build_pair( ...
    partial_final_keep(45), partial_final_keep(30));
eeg.dur_hr = 2.8;
edf.dur_hr = 2.6;
[visibility_cleanup, figure_cleanup] = prepare_hidden_alignment_figure; %#ok<ASGLU>

[result, ~, ~] = match_triggers(eeg, edf, true);

figure_handle = findobj(groot, ...
    'Type', 'figure', 'Tag', 'match_trigger_alignment');
ax_original = findobj(figure_handle, 'Tag', 'original_eeg_timeline');
ax_aligned = findobj(figure_handle, 'Tag', 'aligned_eeg_timeline');
drop_bars = findall(ax_aligned, 'Tag', 'terminal_drop');
verifyNumElements(testCase, drop_bars, 1)
verifyEqual(testCase, drop_bars.Color, [1, 1, 1])
drop_x = drop_bars.XData(isfinite(drop_bars.XData));
expected_eeg_shift_hr = 100 ./ 3600;
verifyEqual(testCase, min(drop_x), edf.dur_hr, 'AbsTol', 1e-12)
verifyEqual(testCase, max(drop_x), ...
    eeg.dur_hr + expected_eeg_shift_hr, 'AbsTol', 1e-12)
verifyEmpty(testCase, findall(ax_aligned, 'Tag', 'terminal_zero_padding'))
aligned_terminal_trace = find_chunk_trace( ...
    ax_aligned, result.eeg_terminal_chunk_indices(1));
aligned_terminal_color = vertcat(aligned_terminal_trace.Color);
verifyTrue(testCase, any(all(aligned_terminal_color == 1, 2)))
verifyTrue(testCase, any(~all(aligned_terminal_color == 1, 2)))
is_white_trace = arrayfun( ...
    @(handle) all(handle.Color == 1), aligned_terminal_trace);
white_trace = aligned_terminal_trace(is_white_trace);
white_x = [white_trace.XData];
first_truncated_trigger = result.eeg_terminal_anchor_event_index + 1;
expected_white_start_hr = ( ...
    double(eeg.event_table.latency(first_truncated_trigger)) - 1) ./ ...
    eeg.Fs ./ 3600 + expected_eeg_shift_hr;
expected_white_end_hr = ( ...
    double(eeg.event_table.latency(end)) - 1) ./ eeg.Fs ./ 3600 + ...
    expected_eeg_shift_hr;
verifyEqual(testCase, min(white_x), expected_white_start_hr, ...
    'AbsTol', 1e-12)
verifyEqual(testCase, max(white_x), expected_white_end_hr, ...
    'AbsTol', 1e-12)
original_terminal_trace = find_chunk_trace( ...
    ax_original, result.eeg_terminal_chunk_indices(1));
original_terminal_color = vertcat(original_terminal_trace.Color);
verifyTrue(testCase, any(all(original_terminal_color == 0, 2)))
verifyFalse(testCase, any(all(original_terminal_color == 1, 2)))
end

function [visibility_cleanup, figure_cleanup] = ...
    prepare_hidden_alignment_figure

close(findobj(groot, 'Type', 'figure', 'Tag', 'match_trigger_alignment'))
previous_visibility = get(groot, 'DefaultFigureVisible');
set(groot, 'DefaultFigureVisible', 'off')
visibility_cleanup = onCleanup( ...
    @() set(groot, 'DefaultFigureVisible', previous_visibility));
figure_cleanup = onCleanup( ...
    @() close(findobj( ...
        groot, 'Type', 'figure', 'Tag', 'match_trigger_alignment')));

end

function trace = find_chunk_trace(ax, chunk_i)

trace = findall(ax, 'Tag', 'trigger_chunk');
is_chunk = arrayfun(@(handle) handle.UserData == chunk_i, trace);
trace = trace(is_chunk);

end

function [result, eeg_output, edf_output] = run_match(eeg_input, edf_input)

[result, eeg_output, edf_output] = match_triggers(eeg_input, edf_input);

end

function [eeg, edf, tolerance_sec] = build_pair(eeg_keep, edf_keep)

eeg.Fs = 500;
edf.Fs = 256;
edf.trigger_Fs = 128;
tolerance_sec = 2 / min([eeg.Fs, edf.trigger_Fs]);

[eeg.event_table, eeg.canonical_cycle, eeg.chunk_report] = ...
    build_system(eeg.Fs, 0, eeg_keep, tolerance_sec);
[edf.event_table, edf.canonical_cycle, edf.chunk_report] = ...
    build_system(edf.trigger_Fs, 100, edf_keep, tolerance_sec);

end

function [event_table, canonical_cycle, chunk_report] = ...
    build_system(Fs, start_time_sec, keep_by_cycle, tolerance_sec)

[canonical_type, canonical_interval_sec, canonical_time_sec] = ...
    canonical_template;
cycle_duration_sec = sum(canonical_interval_sec);
event_time_sec = zeros(0, 1);
event_type = strings(0, 1);

for cycle_i = 1:numel(keep_by_cycle)
    keep_index = keep_by_cycle{cycle_i};
    cycle_start_sec = start_time_sec + (cycle_i - 1) * cycle_duration_sec;
    event_time_sec = [event_time_sec; ...
        cycle_start_sec + canonical_time_sec(keep_index)]; %#ok<AGROW>
    event_type = [event_type; canonical_type(keep_index)]; %#ok<AGROW>
end

latency = round(event_time_sec .* Fs) + 1;
event_table = table(latency, event_type, ...
    'VariableNames', {'latency', 'type'});
[canonical_cycle, ~, chunk_report] = extract_canonical_cycle( ...
    event_table, Fs, tolerance_sec);

end

function keep_by_cycle = complete_keep

keep_by_cycle = repmat({(1:50)'}, 5, 1);

end

function keep_by_cycle = forty_nine_trigger_keep

keep_by_cycle = repmat({setdiff((1:50)', 25, 'stable')}, 5, 1);

end

function keep_by_cycle = partial_final_keep(trigger_count)

keep_by_cycle = complete_keep;
keep_by_cycle{5} = (1:trigger_count)';

end

function keep_by_cycle = continued_after_boundary_keep

keep_by_cycle = complete_keep;
keep_by_cycle{6} = (1:10)';

end

function keep_by_cycle = short_loss_partial_final_keep

keep_by_cycle = short_loss_keep;
keep_by_cycle{5} = (1:30)';

end

function keep_by_cycle = six_cycle_short_loss_keep

keep_by_cycle = repmat({(1:50)'}, 6, 1);
keep_by_cycle{2} = setdiff((1:50)', (12:13)', 'stable');

end

function keep_by_cycle = six_complete_keep

keep_by_cycle = repmat({(1:50)'}, 6, 1);

end

function keep_by_cycle = edf_aborted_startup_keep

keep_by_cycle = six_complete_keep;
keep_by_cycle{1} = (1:10)';

end

function keep_by_cycle = first_chunk_short_loss_keep

keep_by_cycle = six_complete_keep;
keep_by_cycle{1} = setdiff((1:50)', (12:13)', 'stable');

end

function keep_by_cycle = first_chunk_missing_boundary_keep

keep_by_cycle = six_complete_keep;
keep_by_cycle{2} = (7:50)';

end

function keep_by_cycle = six_cycle_late_short_loss_keep

keep_by_cycle = repmat({(1:50)'}, 6, 1);
keep_by_cycle{4} = setdiff((1:50)', (12:13)', 'stable');

end

function keep_by_cycle = four_complete_keep

keep_by_cycle = repmat({(1:50)'}, 4, 1);

end

function keep_by_cycle = late_missing_boundary_keep

keep_by_cycle = complete_keep;
keep_by_cycle{4} = (7:50)';

end

function keep_by_cycle = short_loss_keep

keep_by_cycle = complete_keep;
keep_by_cycle{2} = setdiff((1:50)', (12:13)', 'stable');

end

function keep_by_cycle = different_short_loss_keep

keep_by_cycle = complete_keep;
keep_by_cycle{2} = setdiff((1:50)', 20, 'stable');

end

function keep_by_cycle = late_short_loss_keep

keep_by_cycle = complete_keep;
keep_by_cycle{4} = setdiff((1:50)', (12:13)', 'stable');

end

function keep_by_cycle = missing_boundary_keep

keep_by_cycle = complete_keep;
keep_by_cycle{3} = (7:50)';

end

function [type, interval_to_next_sec, relative_time_sec] = ...
    canonical_template

type = [repmat("64", 4, 1); repmat("63", 46, 1)];
interval_to_next_sec = (10:59)';
relative_time_sec = [0; cumsum(interval_to_next_sec(1:end - 1))];

end
