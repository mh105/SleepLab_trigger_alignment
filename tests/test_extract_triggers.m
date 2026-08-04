function tests = test_extract_triggers
tests = functiontests(localfunctions);
end

function setupOnce(~)
project_path = fileparts(fileparts(mfilename('fullpath')));
addpath(project_path)
addpath(fullfile(project_path, 'helper_functions'))
end

function testNoMarkerCreatesEmptySidecarAndExtractsEdf(testCase)
[eeg_input, edf_input, expected_alignment_types] = build_inputs([], strings(0, 1));

[eeg_output, edf_output] = extract_triggers(eeg_input, edf_input);

expected_variables = { ...
    'interruption_id', 'pairing_status', ...
    'disconnect_raw_event_index', 'disconnect_latency', ...
    'disconnect_event_text', ...
    'reconnect_raw_event_index', 'reconnect_latency', ...
    'reconnect_event_text', ...
    'eeg_start_anchor_event_index', 'eeg_start_anchor_latency', ...
    'eeg_end_anchor_event_index', 'eeg_end_anchor_latency'};
verifySize(testCase, eeg_output.amplifier_interruptions, [0, 12])
verifyEqual(testCase, ...
    eeg_output.amplifier_interruptions.Properties.VariableNames, ...
    expected_variables)
verifyEqual(testCase, eeg_output.event_table.type, expected_alignment_types)
verifyEqual(testCase, edf_output.event_table.type, expected_alignment_types)
verifyEqual(testCase, edf_output.trig_index, edf_output.event_table.latency)
verifyEqual(testCase, edf_output.trig_diff_sec, ...
    diff((double(edf_output.trig_index) - 1) ./ edf_input.trigger_Fs))
end

function testEdfWithoutValidationRetainsLeading63Triggers(testCase)
edf_trigger_type = [ ...
    repmat("63", 3, 1); ...
    repmat("64", 4, 1); ...
    repmat("63", 6, 1)];
[eeg_input, edf_input] = build_inputs( ...
    [], strings(0, 1), edf_trigger_type);

[~, edf_output] = extract_triggers(eeg_input, edf_input);

verifyEqual(testCase, edf_output.event_table.type, edf_trigger_type)
verifyEqual(testCase, edf_output.validation_sequence_count, 0)
verifySize(testCase, edf_output.validation_sequences, [0, 2])
verifyTrue(testCase, isnan(edf_output.last_validation_start_latency))
verifyTrue(testCase, isnan(edf_output.last_validation_end_latency))
verifyEqual(testCase, ...
    edf_output.pre_authoritative_validation_event_count, 0)
end

function testFinalEdfValidationIsAuthoritative(testCase)
validation_type = ["1"; "2"; "4"; "8"; "16"; "32"; "64"];
pre_authoritative_type = [ ...
    repmat("64", 4, 1); repmat("63", 3, 1)];
post_authoritative_type = [ ...
    repmat("64", 4, 1); repmat("63", 6, 1)];
edf_trigger_type = [ ...
    validation_type; ...
    pre_authoritative_type; ...
    validation_type; ...
    post_authoritative_type];
[eeg_input, edf_input] = build_inputs( ...
    [], strings(0, 1), edf_trigger_type);

[~, edf_output] = extract_triggers(eeg_input, edf_input);

verifyEqual(testCase, edf_output.validation_sequence_count, 2)
verifyEqual(testCase, edf_output.validation_sequences.start_latency, [5; 145])
verifyEqual(testCase, edf_output.validation_sequences.end_latency, [65; 205])
verifyEqual(testCase, edf_output.last_validation_start_latency, 145)
verifyEqual(testCase, edf_output.last_validation_end_latency, 205)
verifyEqual(testCase, ...
    edf_output.pre_authoritative_validation_event_count, ...
    numel(pre_authoritative_type))
verifyEqual(testCase, edf_output.event_table.type, ...
    [pre_authoritative_type; post_authoritative_type])
end

function testPairedMarkersAllowFlexibleWordingAndPreserveRawText(testCase)
marker_latency = [2501; 2601];
marker_type = [ ...
    "  9001 , custom disconnect wording  "; ...
    "9002,custom reconnect wording"];
[eeg_input, edf_input] = build_inputs(marker_latency, marker_type);

[eeg_output, ~] = extract_triggers(eeg_input, edf_input);
interruptions = eeg_output.amplifier_interruptions;

verifyEqual(testCase, height(interruptions), 1)
verifyEqual(testCase, interruptions.pairing_status, "paired")
verifyEqual(testCase, interruptions.disconnect_event_text, marker_type(1))
verifyEqual(testCase, interruptions.reconnect_event_text, marker_type(2))
verifyEqual(testCase, interruptions.disconnect_latency, marker_latency(1))
verifyEqual(testCase, interruptions.reconnect_latency, marker_latency(2))
verifyEqual(testCase, interruptions.eeg_start_anchor_event_index, 2)
verifyEqual(testCase, interruptions.eeg_start_anchor_latency, 2001)
verifyEqual(testCase, interruptions.eeg_end_anchor_event_index, 3)
verifyEqual(testCase, interruptions.eeg_end_anchor_latency, 3001)
verifyEqual(testCase, ...
    string(eeg_input.EEG.event( ...
    interruptions.disconnect_raw_event_index).type), marker_type(1))
verifyEqual(testCase, ...
    string(eeg_input.EEG.event( ...
    interruptions.reconnect_raw_event_index).type), marker_type(2))
end

function testNearMatchToLeadingCodeIsRejected(testCase)
[eeg_input, edf_input] = build_inputs(2501, ...
    "90010, Amplifier disconnected");

verifyError(testCase, @() extract_triggers(eeg_input, edf_input), ...
    'extract_triggers:UnexpectedEEGEventType')
end

function testMalformedMarkerAlternationFails(testCase)
verifyMalformed(testCase, 2501, "9002, Amplifier reconnected")
verifyMalformed(testCase, [2501; 2601], [ ...
    "9001, Amplifier disconnected"; ...
    "9001, Amplifier disconnected again"])
verifyMalformed(testCase, [2501; 2601; 2701], [ ...
    "9001, Amplifier disconnected"; ...
    "9002, Amplifier reconnected"; ...
    "9002, Amplifier reconnected again"])
end

function testTerminalUnmatchedDisconnectUsesLastTrustedAnchor(testCase)
[eeg_input, edf_input] = build_inputs(8501, ...
    "9001, Amplifier disconnected");

[eeg_output, ~] = extract_triggers(eeg_input, edf_input);
interruption = eeg_output.amplifier_interruptions;

verifyEqual(testCase, interruption.pairing_status, "missing_reconnect")
verifyEqual(testCase, interruption.eeg_start_anchor_event_index, 8)
verifyEqual(testCase, interruption.eeg_start_anchor_latency, 8001)
verifyTrue(testCase, isnan(interruption.reconnect_raw_event_index))
verifyTrue(testCase, isnan(interruption.reconnect_latency))
verifyTrue(testCase, isnan(interruption.eeg_end_anchor_event_index))
verifyTrue(testCase, isnan(interruption.eeg_end_anchor_latency))
end

function testCoincidentMarkersUseInclusiveAnchors(testCase)
[eeg_input, edf_input] = build_inputs([2001; 4001], [ ...
    "9001, Amplifier disconnected"; ...
    "9002, Amplifier reconnected"]);

[eeg_output, ~] = extract_triggers(eeg_input, edf_input);
interruption = eeg_output.amplifier_interruptions;

verifyEqual(testCase, interruption.eeg_start_anchor_event_index, 2)
verifyEqual(testCase, interruption.eeg_start_anchor_latency, 2001)
verifyEqual(testCase, interruption.eeg_end_anchor_event_index, 4)
verifyEqual(testCase, interruption.eeg_end_anchor_latency, 4001)
end

function testMultiplePairsInOneIntervalRemainSeparate(testCase)
[eeg_input, edf_input] = build_inputs( ...
    [2201; 2301; 2401; 2501], [ ...
    "9001, first disconnect"; ...
    "9002, first reconnect"; ...
    "9001, second disconnect"; ...
    "9002, second reconnect"]);

[eeg_output, ~] = extract_triggers(eeg_input, edf_input);
interruptions = eeg_output.amplifier_interruptions;

verifyEqual(testCase, height(interruptions), 2)
verifyEqual(testCase, interruptions.interruption_id, [1; 2])
verifyEqual(testCase, interruptions.pairing_status, repmat("paired", 2, 1))
verifyEqual(testCase, ...
    interruptions.eeg_start_anchor_event_index, [2; 2])
verifyEqual(testCase, interruptions.eeg_start_anchor_latency, [2001; 2001])
verifyEqual(testCase, interruptions.eeg_end_anchor_event_index, [3; 3])
verifyEqual(testCase, interruptions.eeg_end_anchor_latency, [3001; 3001])
end

function verifyMalformed(testCase, marker_latency, marker_type)
[eeg_input, edf_input] = build_inputs(marker_latency, marker_type);
verifyError(testCase, @() extract_triggers(eeg_input, edf_input), ...
    'extract_triggers:MalformedAmplifierSequence')
end

function [eeg_input, edf_input, alignment_type] = ...
    build_inputs(marker_latency, marker_type, edf_trigger_type)

validation_type = ["1"; "2"; "4"; "8"; "16"; "32"; "64"];
validation_latency = (101:100:701)';
alignment_type = [repmat("64", 4, 1); repmat("63", 6, 1)];
alignment_latency = (1001:1000:10001)';

if nargin < 3
    edf_trigger_type = [validation_type; alignment_type];
end

event_type = [validation_type; alignment_type; marker_type(:)];
event_latency = [validation_latency; alignment_latency; marker_latency(:)];
original_order = (1:numel(event_latency))';
[~, sort_index] = sortrows([event_latency, original_order], [1, 2]);
event_type = event_type(sort_index);
event_latency = event_latency(sort_index);

event = repmat(struct('latency', NaN, 'type', ''), 1, numel(event_latency));
for event_i = 1:numel(event_latency)
    event(event_i).latency = event_latency(event_i);
    event(event_i).type = char(event_type(event_i));
end

eeg_input.EEG.event = event;
eeg_input.EEG.pnts = max(event_latency) + 1000;
eeg_input.Fs = 500;

edf_input.trigger_Fs = 128;
edf_input.Fs = 256;
edf_input.DC_trace = build_edf_trace(edf_trigger_type);
end

function DC_trace = build_edf_trace(trigger_type)
trigger_voltage = nan(size(trigger_type));
trigger_voltage(trigger_type == "1") = 5.5;
trigger_voltage(trigger_type == "2") = 11.5;
trigger_voltage(trigger_type == "4") = 18.5;
trigger_voltage(trigger_type == "8") = 24.5;
trigger_voltage(trigger_type == "16") = 30.5;
trigger_voltage(trigger_type == "32" | trigger_type == "63") = 36.5;
trigger_voltage(trigger_type == "64") = 42.5;

trigger_latency = (5:10:(5 + 10 * (numel(trigger_type) - 1)))';
DC_trace = zeros(trigger_latency(end) + 5, 1);
for trigger_i = 1:numel(trigger_latency)
    pulse_index = trigger_latency(trigger_i):(trigger_latency(trigger_i) + 2);
    DC_trace(pulse_index) = trigger_voltage(trigger_i);
end
end
