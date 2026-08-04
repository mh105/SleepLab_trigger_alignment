function [eeg_input, edf_input] = extract_triggers(eeg_input, edf_input, plot_intervals)
if nargin < 3
    plot_intervals = false;
end

%% Compute the total durations
eeg_input.dur_hr = eeg_input.EEG.pnts / eeg_input.Fs / (60*60);
edf_input.dur_hr = length(edf_input.DC_trace) / edf_input.trigger_Fs / (60*60);

%% build trigger table from the HD-EEG data
EEG = eeg_input.EEG;

event_idx = (1:numel(EEG.event))';
latency = [EEG.event.latency]';
event_type = arrayfun(@(ev) string(ev.type), EEG.event)';
event_type = strip(event_type);

is_impedance = contains(lower(event_type), "impedance");
is_boundary = strcmpi(event_type, "boundary");

% Remove the initial validation sequence: 1, 2, 4, 8, 16, 32, 64
candidate_idx = find(~is_impedance & ~is_boundary);
validation_pattern = ["1"; "2"; "4"; "8"; "16"; "32"; "64"];

assert(numel(candidate_idx) >= numel(validation_pattern), ...
    'Not enough non-impedance/non-boundary EEG events to contain validation sequence.')

validation_idx = candidate_idx(1:numel(validation_pattern));
assert(isequal(event_type(validation_idx), validation_pattern), ...
    'Initial EEG validation trigger sequence does not match 1,2,4,8,16,32,64.')

is_validation = false(size(event_type));
is_validation(validation_idx) = true;

use_alignment = ~(is_impedance | is_boundary | is_validation);

% After filtering, alignment triggers should only be 63 or 64
unexpected_types = setdiff(unique(event_type(use_alignment)), ["63"; "64"]);
assert(isempty(unexpected_types), ...
    'Unexpected EEG event type(s) remain after filtering.')

eeg_alignment_event_table = table( ...
    event_idx(use_alignment), ...
    latency(use_alignment), ...
    event_type(use_alignment), ...
    'VariableNames', {'event_idx', 'latency', 'type'});

% Sanity check: remaining 64 triggers should occur in runs of exactly 4
is64 = eeg_alignment_event_table.type == "64";
run_edges = diff([false; is64; false]);
run_start = find(run_edges == 1);
run_end = find(run_edges == -1) - 1;
run_lengths = run_end - run_start + 1;

assert(all(run_lengths == 4), ...
    'One or more post-validation 64-trigger runs does not have length 4.')

% store the event table and trigger index in samples
eeg_input.event_table = eeg_alignment_event_table;
eeg_input.trig_index = eeg_input.event_table.latency;

%% build trigger table from EDF trigger channel
zero_tolerance = 1;
DC_channel_trace = edf_input.DC_trace(:);
is_trigger_sample = DC_channel_trace > zero_tolerance;

trigger_edges = diff([false; is_trigger_sample; false]);
trigger_latency = find(trigger_edges == 1);
trigger_offset = find(trigger_edges == -1) - 1;

trigger_voltage_ranges = [
    5 6
    11 12.1
    18 19
    24 25
    30 31
    36 37
    42 43];
trigger_codes = ["1"; "2"; "4"; "8"; "16"; "63"; "64"];

split_63_64_min_samples = 3;
range_63 = trigger_voltage_ranges(trigger_codes == "63", :);
range_64 = trigger_voltage_ranges(trigger_codes == "64", :);
split_trigger_latency = zeros(0, 1);
split_trigger_offset = zeros(0, 1);
split_63_64_count = 0;

for trigger_i = 1:numel(trigger_latency)
    trigger_values = DC_channel_trace(trigger_latency(trigger_i):trigger_offset(trigger_i));
    in_63_range = trigger_values >= range_63(1) & trigger_values <= range_63(2);
    in_64_range = trigger_values >= range_64(1) & trigger_values <= range_64(2);

    range_63_edges = diff([false; in_63_range; false]);
    range_63_start = find(range_63_edges == 1);
    range_63_end = find(range_63_edges == -1) - 1;
    range_63_lengths = range_63_end - range_63_start + 1;
    valid_63_runs = range_63_lengths >= split_63_64_min_samples;

    range_64_edges = diff([false; in_64_range; false]);
    range_64_start = find(range_64_edges == 1);
    range_64_end = find(range_64_edges == -1) - 1;
    range_64_lengths = range_64_end - range_64_start + 1;
    valid_64_runs = range_64_lengths >= split_63_64_min_samples;

    split_63_end = [];
    split_64_start = [];
    for run_i = find(valid_64_runs)'
        prior_63_run = find(valid_63_runs & range_63_end < range_64_start(run_i), 1, 'last');
        if ~isempty(prior_63_run)
            split_63_end = range_63_end(prior_63_run);
            split_64_start = range_64_start(run_i);
            break
        end
    end

    if isempty(split_64_start)
        split_trigger_latency(end + 1, 1) = trigger_latency(trigger_i); %#ok<*AGROW>
        split_trigger_offset(end + 1, 1) = trigger_offset(trigger_i);
    else
        split_trigger_latency(end + 1, 1) = trigger_latency(trigger_i);
        split_trigger_offset(end + 1, 1) = trigger_latency(trigger_i) + split_63_end - 1;
        split_trigger_latency(end + 1, 1) = trigger_latency(trigger_i) + split_64_start - 1;
        split_trigger_offset(end + 1, 1) = trigger_offset(trigger_i);
        split_63_64_count = split_63_64_count + 1;
    end
end

trigger_latency = split_trigger_latency;
trigger_offset = split_trigger_offset;
fprintf('EDF merged 63-to-64 trigger chunks split: %d\n', split_63_64_count);

trigger_max_value = nan(numel(trigger_latency), 1);
for trigger_i = 1:numel(trigger_latency)
    trigger_values = DC_channel_trace(trigger_latency(trigger_i):trigger_offset(trigger_i));
    trigger_max_value(trigger_i) = max(trigger_values);
end

trigger_type = repmat("orphan", numel(trigger_latency), 1);
for trigger_i = 1:numel(trigger_codes)
    in_range = trigger_max_value >= trigger_voltage_ranges(trigger_i, 1) & ...
        trigger_max_value <= trigger_voltage_ranges(trigger_i, 2);
    trigger_type(in_range) = trigger_codes(trigger_i);
end

ambiguous_32_pattern = ["1"; "2"; "4"; "8"; "16"; "63"; "64"];
ambiguous_32_length = numel(ambiguous_32_pattern);
for trigger_i = 1:(numel(trigger_type) - ambiguous_32_length + 1)
    validation_idx = trigger_i:(trigger_i + ambiguous_32_length - 1);
    if isequal(trigger_type(validation_idx), ambiguous_32_pattern)
        trigger_type(validation_idx(6)) = "32";
    end
end

edf_trigger_table = table( ...
    trigger_latency, ...
    trigger_max_value, ...
    trigger_type, ...
    'VariableNames', {'latency', 'max_value', 'type'});

orphan_trigger_table = edf_trigger_table(edf_trigger_table.type == "orphan", :);
fprintf('EDF orphan triggers outside voltage mapping ranges: %d\n', height(orphan_trigger_table));

use_edf_alignment = edf_trigger_table.type ~= "orphan";

edf_validation_pattern = ["1"; "2"; "4"; "8"; "16"; "32"; "64"];
is_edf_validation = false(height(edf_trigger_table), 1);
for trigger_i = 1:(height(edf_trigger_table) - numel(edf_validation_pattern) + 1)
    validation_idx = trigger_i:(trigger_i + numel(edf_validation_pattern) - 1);
    if isequal(edf_trigger_table.type(validation_idx), edf_validation_pattern)
        is_edf_validation(validation_idx) = true;
    end
end

assert(any(is_edf_validation), ...
    'Initial EDF validation trigger sequence does not match 1,2,4,8,16,32,64.')
use_edf_alignment(is_edf_validation) = false;

edf_is64 = edf_trigger_table.type == "64";
edf_run_edges = diff([false; edf_is64; false]);
edf_run_start = find(edf_run_edges == 1);
edf_run_end = find(edf_run_edges == -1) - 1;
edf_run_lengths = edf_run_end - edf_run_start + 1;

remove_64 = false(height(edf_trigger_table), 1);
for run_i = 1:numel(edf_run_lengths)
    is_validation_plus_four_64s = edf_run_lengths(run_i) == 5 && ...
        is_edf_validation(edf_run_start(run_i));
    if edf_run_lengths(run_i) ~= 4 && ~is_validation_plus_four_64s
        remove_64(edf_run_start(run_i):edf_run_end(run_i)) = true;
    end
end

non_four_64_trigger_table = edf_trigger_table(remove_64, :);
fprintf('EDF 64 triggers outside runs of exactly 4 removed: %d\n', height(non_four_64_trigger_table));
use_edf_alignment(remove_64) = false;

edf_alignment_event_table = edf_trigger_table(use_edf_alignment, :);

unexpected_edf_types = setdiff(unique(edf_alignment_event_table.type), ["63"; "64"]);
assert(isempty(unexpected_edf_types), ...
    'Unexpected EDF trigger type(s) remain after filtering.')

edf_is64 = edf_alignment_event_table.type == "64";
edf_run_edges = diff([false; edf_is64; false]);
edf_run_start = find(edf_run_edges == 1);
edf_run_end = find(edf_run_edges == -1) - 1;
edf_run_lengths = edf_run_end - edf_run_start + 1;

assert(all(edf_run_lengths == 4), ...
    'One or more post-validation EDF 64-trigger runs does not have length 4.')

% store the event table and trigger index in samples
edf_input.event_table = edf_alignment_event_table;
edf_input.trig_index = edf_input.event_table.latency;

%% Extract trigger latencies and plot them
% Compute the latencies in seconds
eeg_trig_latency_sec = ...
    (eeg_alignment_event_table.latency - 1) ./ eeg_input.Fs;
edf_trig_latency_sec = ...
    (edf_alignment_event_table.latency - 1) ./ edf_input.trigger_Fs;

eeg_trig_diff_sec = diff(eeg_trig_latency_sec);
edf_trig_diff_sec = diff(edf_trig_latency_sec);

eeg_input.trig_diff_sec = eeg_trig_diff_sec;
edf_input.trig_diff_sec = edf_trig_diff_sec;

if plot_intervals
    figure

    ax1 = subplot(3,1,1);
    plot(eeg_trig_diff_sec, '-o', 'Linewidth', 1)
    set(ax1, 'FontSize', 16)
    title('HD-EEG', 'FontSize', 24)
    ylabel('Duration (sec)')

    ax2 = subplot(3,1,2);
    plot(edf_trig_diff_sec, '-or', 'Linewidth', 1)
    set(ax2, 'FontSize', 16)
    title('Clinical EDF', 'FontSize', 24)
    ylabel('Duration (sec)')

    ax3 = subplot(3,1,3);
    hold on
    plot(eeg_trig_diff_sec, '-o', 'Linewidth', 1)
    plot(edf_trig_diff_sec, '-or', 'Linewidth', 1)
    set(ax3, 'FontSize', 16)
    legend('EEG', 'EDF', 'FontSize', 20)
    title('Overlaid', 'FontSize', 24)
    ylabel('Duration (sec)')
    xlabel('Trigger difference interval index')

    linkaxes([ax1, ax2, ax3], 'xy')
end

end
