function matched_segments = extract_segments( ...
    trigger_match_result, eeg_input, edf_input, plot_drift)
%EXTRACT_SEGMENTS Extract maximal runs of paired trigger intervals.
%   MATCHED_SEGMENTS = EXTRACT_SEGMENTS(RESULT, EEG_INPUT, EDF_INPUT)
%   reconstructs the matched trigger intervals recorded by MATCH_TRIGGERS,
%   separates them at unsafe gaps, prints the resulting segment table, and
%   returns it for later processing. Interval k means canonical interval
%   Tk -> T(k+1); a bounded chunk's last interval reaches the next chunk.
%   Amplifier-interruption intervals flagged by MATCH_TRIGGERS are omitted
%   explicitly, including marked multi-interval spans whose timing matches.
%   EDF durations refer to the EDF trigger channel.
%   Each segment's cumulative EDF-minus-EEG difference is fit against EEG
%   elapsed time. The function errors when a fit residual exceeds the
%   interval tolerance returned by MATCH_TRIGGERS.
%   EXTRACT_SEGMENTS(..., PLOT_DRIFT) plots the cumulative EDF-minus-
%   EEG trigger-timing difference against elapsed time for every continuous
%   segment.

if nargin < 4
    plot_drift = false;
end

validate_inputs(trigger_match_result, eeg_input, edf_input)

history = trigger_match_result.comparison_history;
interval_pairs = empty_interval_pair_table;
alignment_locked = true;

for history_i = 1:height(history)
    outcome = history.outcome(history_i);
    eeg_chunk_i = history.eeg_chunk_index(history_i);
    edf_chunk_i = history.edf_chunk_index(history_i);

    if outcome == "shared_trigger_glitch" && ~alignment_locked
        continue
    end

    if any(outcome == ["match", "shared_trigger_glitch"])
        eeg_edges = extract_chunk_edges(eeg_input, eeg_chunk_i);
        edf_edges = extract_chunk_edges(edf_input, edf_chunk_i);
        assert(height(eeg_edges) == height(edf_edges), ...
            'Paired trigger chunks must contain the same number of intervals.')

        if outcome == "match"
            interval_number = (1:height(eeg_edges))';
        else
            canonical = extract_canonical_edges(eeg_input.canonical_cycle);
            interval_number = infer_canonical_interval_numbers( ...
                eeg_edges, canonical, ...
                trigger_match_result.interval_tolerance_sec);
        end
        interval_pairs = [interval_pairs; make_interval_pairs( ...
            eeg_edges, edf_edges, interval_number)]; %#ok<AGROW>
        if outcome == "match"
            alignment_locked = true;
        end
    elseif any(outcome == ["eeg_data_loss", "edf_data_loss"])
        if ~alignment_locked
            continue
        end
        [loss_pairs, amplifier_pairing_used] = ...
            amplifier_loss_interval_pairs( ...
                history(history_i, :), trigger_match_result, ...
                eeg_input, edf_input);
        if amplifier_pairing_used
            alignment_locked = true;
        else
            [loss_pairs, alignment_locked] = loss_interval_pairs( ...
                history(history_i, :), outcome, trigger_match_result, ...
                eeg_input, edf_input);
        end
        interval_pairs = [interval_pairs; loss_pairs]; %#ok<AGROW>
    elseif outcome == "both_systems_unusable"
        if alignment_locked
            interval_pairs = [interval_pairs; shared_prefix_pairs( ...
                eeg_chunk_i, edf_chunk_i, trigger_match_result, ...
                eeg_input, edf_input)]; %#ok<AGROW>
        end
        alignment_locked = false;
    elseif any(outcome == ["eeg_shorter", "eeg_longer", ...
            "same_last_trigger"])
        if alignment_locked
            interval_pairs = [interval_pairs; terminal_interval_pairs( ...
                trigger_match_result, eeg_input, edf_input)]; %#ok<AGROW>
        end
    else
        error('extract_segments:UnknownOutcome', ...
            'Unsupported comparison-history outcome: %s.', outcome)
    end
end

interval_pairs = exclude_amplifier_intervals( ...
    interval_pairs, trigger_match_result);

if isempty(interval_pairs)
    error('extract_segments:NoMatchedIntervals', ...
        'No matched trigger intervals are available to report.')
end

assert(all(diff(interval_pairs.eeg_source_event_index) > 0) && ...
    all(diff(interval_pairs.edf_source_event_index) > 0), ...
    'Matched trigger intervals must remain chronological in both systems.')

starts_segment = [true; ...
    interval_pairs.eeg_source_event_index(2:end) ~= ...
        interval_pairs.eeg_destination_event_index(1:end - 1) | ...
    interval_pairs.edf_source_event_index(2:end) ~= ...
        interval_pairs.edf_destination_event_index(1:end - 1)];
start_row = find(starts_segment);
end_row = [start_row(2:end) - 1; height(interval_pairs)];

segment_index = (1:numel(start_row))';
start_eeg_chunk = interval_pairs.eeg_chunk_index(start_row);
start_edf_chunk = interval_pairs.edf_chunk_index(start_row);
start_interval = interval_pairs.interval_number(start_row);
end_eeg_chunk = interval_pairs.eeg_chunk_index(end_row);
end_edf_chunk = interval_pairs.edf_chunk_index(end_row);
end_interval = interval_pairs.interval_number(end_row);

eeg_start_sample = double(eeg_input.event_table.latency( ...
    interval_pairs.eeg_source_event_index(start_row)));
eeg_end_sample = double(eeg_input.event_table.latency( ...
    interval_pairs.eeg_destination_event_index(end_row)));
edf_start_sample = double(edf_input.event_table.latency( ...
    interval_pairs.edf_source_event_index(start_row)));
edf_end_sample = double(edf_input.event_table.latency( ...
    interval_pairs.edf_destination_event_index(end_row)));

eeg_sample_span = eeg_end_sample - eeg_start_sample;
edf_sample_span = edf_end_sample - edf_start_sample;
eeg_duration_sec = eeg_sample_span ./ eeg_input.Fs;
edf_duration_sec = edf_sample_span ./ edf_input.trigger_Fs;
edf_minus_eeg_sec = edf_duration_sec - eeg_duration_sec;

n_segments = numel(segment_index);
clock_drift_r_squared = zeros(n_segments, 1);
clock_drift_max_abs_residual_sec = zeros(n_segments, 1);
eeg_elapsed_by_segment = cell(n_segments, 1);
cumulative_difference_by_segment = cell(n_segments, 1);

for segment_i = 1:n_segments
    [eeg_elapsed_sec, cumulative_difference_sec] = ...
        segment_drift_series( ...
            interval_pairs, start_row(segment_i), end_row(segment_i), ...
            eeg_input, edf_input);
    [r_squared, max_abs_residual_sec] = ...
        fit_clock_drift(eeg_elapsed_sec, cumulative_difference_sec);

    comparison_scale = max([abs(cumulative_difference_sec); 1]);
    roundoff_tolerance_sec = 10 * eps(comparison_scale);
    linearity_tolerance_sec = ...
        trigger_match_result.interval_tolerance_sec + ...
        roundoff_tolerance_sec;
    if max_abs_residual_sec > linearity_tolerance_sec
        error('extract_segments:NonlinearClockDrift', ...
            ['Continuous segment %d is not consistent with linear clock ' ...
             'drift: maximum detrended residual %.6f s exceeds the ' ...
             '%.6f s tolerance.'], ...
            segment_index(segment_i), max_abs_residual_sec, ...
            trigger_match_result.interval_tolerance_sec)
    end

    clock_drift_r_squared(segment_i) = r_squared;
    clock_drift_max_abs_residual_sec(segment_i) = ...
        max_abs_residual_sec;
    eeg_elapsed_by_segment{segment_i} = eeg_elapsed_sec;
    cumulative_difference_by_segment{segment_i} = ...
        cumulative_difference_sec;
end

matched_segments = table( ...
    segment_index, ...
    eeg_duration_sec, edf_duration_sec, edf_minus_eeg_sec, ...
    clock_drift_r_squared, clock_drift_max_abs_residual_sec, ...
    start_eeg_chunk, start_edf_chunk, start_interval, ...
    end_eeg_chunk, end_edf_chunk, end_interval, ...
    eeg_start_sample, eeg_end_sample, edf_start_sample, edf_end_sample);

display_report = matched_segments;
display_report.eeg_duration_sec = categorical(compose( ...
    "%.5f", matched_segments.eeg_duration_sec));
display_report.edf_duration_sec = categorical(compose( ...
    "%.5f", matched_segments.edf_duration_sec));
display_report.clock_drift_r_squared = categorical(compose( ...
    "%.5f", matched_segments.clock_drift_r_squared));
display_report.clock_drift_max_abs_residual_sec = categorical(compose( ...
    "%.5f", matched_segments.clock_drift_max_abs_residual_sec));
disp('Continuous matched-trigger segments:')
disp(display_report)

if plot_drift
    plot_clock_drift( ...
        segment_index, eeg_elapsed_by_segment, ...
        cumulative_difference_by_segment)
end

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% END OF EXTRACT_SEGMENTS (MAIN FUNCTION)
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
end

%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% ADDITIONAL HELPER FUNCTIONS
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
function [eeg_elapsed_sec, cumulative_difference_sec] = ...
    segment_drift_series( ...
        interval_pairs, start_row, end_row, eeg_input, edf_input)

row_index = (start_row:end_row)';
eeg_event_index = [ ...
    interval_pairs.eeg_source_event_index(row_index); ...
    interval_pairs.eeg_destination_event_index(end_row)];
edf_event_index = [ ...
    interval_pairs.edf_source_event_index(row_index); ...
    interval_pairs.edf_destination_event_index(end_row)];

eeg_latency = double(eeg_input.event_table.latency(eeg_event_index));
edf_latency = double(edf_input.event_table.latency(edf_event_index));
eeg_elapsed_sec = (eeg_latency - eeg_latency(1)) ./ eeg_input.Fs;
edf_elapsed_sec = (edf_latency - edf_latency(1)) ./ ...
    edf_input.trigger_Fs;
cumulative_difference_sec = edf_elapsed_sec - eeg_elapsed_sec;

end

%%
function [r_squared, max_abs_residual_sec] = ...
    fit_clock_drift(eeg_elapsed_sec, cumulative_difference_sec)

linear_fit = polyfit(eeg_elapsed_sec, cumulative_difference_sec, 1);
fitted_difference_sec = polyval(linear_fit, eeg_elapsed_sec);
residual_sec = cumulative_difference_sec - fitted_difference_sec;
max_abs_residual_sec = max(abs(residual_sec));

sum_squared_residual = sum(residual_sec .^ 2);
centered_difference_sec = ...
    cumulative_difference_sec - mean(cumulative_difference_sec);
total_sum_squares = sum(centered_difference_sec .^ 2);
comparison_scale = max([abs(cumulative_difference_sec); 1]);
roundoff_sum_squares = ...
    numel(cumulative_difference_sec) * (10 * eps(comparison_scale)) ^ 2;
if numel(cumulative_difference_sec) < 3
    r_squared = NaN;
elseif total_sum_squares <= roundoff_sum_squares
    r_squared = double(sum_squared_residual <= roundoff_sum_squares);
else
    r_squared = 1 - sum_squared_residual ./ total_sum_squares;
end

end

%%
function plot_clock_drift( ...
    segment_index, eeg_elapsed_by_segment, ...
    cumulative_difference_by_segment)

figure
ax = axes;
hold(ax, 'on')
for segment_i = 1:numel(segment_index)
    plot(ax, ...
        eeg_elapsed_by_segment{segment_i} ./ 3600, ...
        cumulative_difference_by_segment{segment_i}, ...
        '-o', 'LineWidth', 1, ...
        'DisplayName', "segment index " + segment_index(segment_i));
end
hold(ax, 'off')
set(ax, 'FontSize', 16)
xlabel(ax, 'Time within continuous segment (hr)')
ylabel(ax, 'Cumulative EDF - EEG duration (sec)')
title(ax, 'Cumulative trigger-timing difference', ...
    'FontSize', 24)
legend(ax, 'show', 'Location', 'best', 'FontSize', 20)
grid(ax, 'on')

end

%%
function [pairs, handled] = amplifier_loss_interval_pairs( ...
    history_row, trigger_match_result, eeg_input, edf_input)

pairs = empty_interval_pair_table;
handled = false;
if ~isfield(trigger_match_result, 'amplifier_interruptions')
    return
end

interruptions = trigger_match_result.amplifier_interruptions;
if isempty(interruptions) || ...
        ~all(ismember( ...
            ["exclude_from_segments", ...
             "eeg_start_anchor_event_index", ...
             "eeg_end_anchor_event_index"], ...
            string(interruptions.Properties.VariableNames)))
    return
end

eeg_edges = extract_chunk_edges( ...
    eeg_input, history_row.eeg_chunk_index);
edf_edges = extract_chunk_edges( ...
    edf_input, history_row.edf_chunk_index);
covered_by_interruption = false(height(eeg_edges), 1);
for interruption_i = find(interruptions.exclude_from_segments)'
    start_anchor = interruptions.eeg_start_anchor_event_index( ...
        interruption_i);
    end_anchor = interruptions.eeg_end_anchor_event_index( ...
        interruption_i);
    if isnan(start_anchor) && isnan(end_anchor)
        row_covered = true(height(eeg_edges), 1);
    elseif isnan(start_anchor)
        row_covered = eeg_edges.source_event_index < end_anchor;
    elseif isnan(end_anchor)
        row_covered = eeg_edges.source_event_index >= start_anchor;
    elseif end_anchor > start_anchor
        row_covered = ...
            eeg_edges.source_event_index >= start_anchor & ...
            eeg_edges.source_event_index < end_anchor;
    else
        row_covered = eeg_edges.source_event_index == start_anchor;
    end
    covered_by_interruption = covered_by_interruption | row_covered;
end
if ~any(covered_by_interruption) || ...
        height(eeg_edges) ~= height(edf_edges) || ...
        ~isequal(eeg_edges.source_type, edf_edges.source_type) || ...
        ~isequal(eeg_edges.destination_type, edf_edges.destination_type)
    return
end

interval_number = (1:height(eeg_edges))';
pairs = make_interval_pairs(eeg_edges, edf_edges, interval_number);
handled = true;

end

%%
function interval_pairs = exclude_amplifier_intervals( ...
    interval_pairs, trigger_match_result)

if isempty(interval_pairs) || ...
        ~isfield(trigger_match_result, 'amplifier_interruptions')
    return
end

interruptions = trigger_match_result.amplifier_interruptions;
required_variables = [ ...
    "exclude_from_segments", ...
    "eeg_start_anchor_event_index", "eeg_end_anchor_event_index"];
if isempty(interruptions) || ...
        ~all(ismember(required_variables, ...
            string(interruptions.Properties.VariableNames)))
    return
end

keep_interval = true(height(interval_pairs), 1);
for interruption_i = find(interruptions.exclude_from_segments)'
    start_anchor = interruptions.eeg_start_anchor_event_index( ...
        interruption_i);
    end_anchor = interruptions.eeg_end_anchor_event_index( ...
        interruption_i);
    if isnan(start_anchor) && isnan(end_anchor)
        unsafe_interval = true(height(interval_pairs), 1);
    elseif isnan(start_anchor)
        unsafe_interval = ...
            interval_pairs.eeg_source_event_index < end_anchor;
    elseif isnan(end_anchor)
        unsafe_interval = ...
            interval_pairs.eeg_source_event_index >= start_anchor;
    elseif end_anchor > start_anchor
        unsafe_interval = ...
            interval_pairs.eeg_source_event_index >= start_anchor & ...
            interval_pairs.eeg_source_event_index < end_anchor;
    else
        unsafe_interval = ...
            interval_pairs.eeg_source_event_index == start_anchor;
    end
    keep_interval(unsafe_interval) = false;
end

interval_pairs = interval_pairs(keep_interval, :);

end

%%
function [pairs, has_matching_suffix] = loss_interval_pairs( ...
    history_row, outcome, trigger_match_result, eeg_input, edf_input)

eeg_chunk_i = history_row.eeg_chunk_index;
edf_chunk_i = history_row.edf_chunk_index;
if outcome == "eeg_data_loss"
    affected_edges = extract_chunk_edges(eeg_input, eeg_chunk_i);
    canonical = extract_canonical_edges(eeg_input.canonical_cycle);
    clean_prefix_edges = extract_chunk_edges(edf_input, edf_chunk_i);
else
    affected_edges = extract_chunk_edges(edf_input, edf_chunk_i);
    canonical = extract_canonical_edges(edf_input.canonical_cycle);
    clean_prefix_edges = extract_chunk_edges(eeg_input, eeg_chunk_i);
end

[prefix_count, suffix_count] = matching_ends( ...
    affected_edges, canonical, ...
    trigger_match_result.interval_tolerance_sec);
has_relock = isfinite(history_row.next_eeg_chunk_index) && ...
    isfinite(history_row.next_edf_chunk_index);
if ~has_relock
    suffix_count = 0;
end
has_matching_suffix = suffix_count > 0;

pairs = empty_interval_pair_table;
if prefix_count > 0
    interval_number = (1:prefix_count)';
    if outcome == "eeg_data_loss"
        pairs = make_interval_pairs( ...
            affected_edges(1:prefix_count, :), ...
            clean_prefix_edges(1:prefix_count, :), interval_number);
    else
        pairs = make_interval_pairs( ...
            clean_prefix_edges(1:prefix_count, :), ...
            affected_edges(1:prefix_count, :), interval_number);
    end
end

if suffix_count == 0
    return
end

if outcome == "eeg_data_loss"
    clean_suffix_chunk_i = history_row.next_edf_chunk_index - 1;
    clean_suffix_edges = extract_chunk_edges( ...
        edf_input, clean_suffix_chunk_i);
else
    clean_suffix_chunk_i = history_row.next_eeg_chunk_index - 1;
    clean_suffix_edges = extract_chunk_edges( ...
        eeg_input, clean_suffix_chunk_i);
end

affected_suffix = affected_edges(end - suffix_count + 1:end, :);
clean_suffix = clean_suffix_edges(end - suffix_count + 1:end, :);
first_suffix_interval = height(canonical) - suffix_count + 1;
interval_number = (first_suffix_interval:height(canonical))';
if outcome == "eeg_data_loss"
    suffix_pairs = make_interval_pairs( ...
        affected_suffix, clean_suffix, interval_number);
else
    suffix_pairs = make_interval_pairs( ...
        clean_suffix, affected_suffix, interval_number);
end
pairs = [pairs; suffix_pairs];

end

%%
function pairs = shared_prefix_pairs( ...
    eeg_chunk_i, edf_chunk_i, trigger_match_result, eeg_input, edf_input)

eeg_edges = extract_chunk_edges(eeg_input, eeg_chunk_i);
edf_edges = extract_chunk_edges(edf_input, edf_chunk_i);
eeg_canonical = extract_canonical_edges(eeg_input.canonical_cycle);
edf_canonical = extract_canonical_edges(edf_input.canonical_cycle);
tolerance_sec = trigger_match_result.interval_tolerance_sec;
eeg_prefix_count = matching_prefix_count( ...
    eeg_edges, eeg_canonical, tolerance_sec);
edf_prefix_count = matching_prefix_count( ...
    edf_edges, edf_canonical, tolerance_sec);
prefix_count = min(eeg_prefix_count, edf_prefix_count);

if prefix_count == 0
    pairs = empty_interval_pair_table;
else
    pairs = make_interval_pairs( ...
        eeg_edges(1:prefix_count, :), edf_edges(1:prefix_count, :), ...
        (1:prefix_count)');
end

end

%%
function pairs = terminal_interval_pairs( ...
    trigger_match_result, eeg_input, edf_input)

n_intervals = trigger_match_result.terminal_common_trigger_count - 1;
if n_intervals < 1
    pairs = empty_interval_pair_table;
    return
end

eeg_chunk_i = trigger_match_result.eeg_terminal_chunk_indices(1);
edf_chunk_i = trigger_match_result.edf_terminal_chunk_indices(1);
eeg_edges = extract_chunk_edges(eeg_input, eeg_chunk_i);
edf_edges = extract_chunk_edges(edf_input, edf_chunk_i);
eeg_edges = eeg_edges(1:n_intervals, :);
edf_edges = edf_edges(1:n_intervals, :);
canonical = extract_canonical_edges(eeg_input.canonical_cycle);
canonical(end, :) = [];
interval_number = infer_canonical_interval_numbers( ...
    eeg_edges, canonical, trigger_match_result.interval_tolerance_sec);
pairs = make_interval_pairs(eeg_edges, edf_edges, interval_number);

end

%%
function edges = extract_chunk_edges(system_input, chunk_i)

event_table = system_input.event_table;
chunk_report = system_input.chunk_report;
if isfield(system_input, 'trigger_Fs')
    Fs = system_input.trigger_Fs;
else
    Fs = system_input.Fs;
end

start_event_index = chunk_report.start_event_index(chunk_i);
end_event_index = chunk_report.end_event_index(chunk_i);
event_index = (start_event_index:end_event_index)';
if chunk_report.has_next_boundary(chunk_i)
    source_event_index = event_index;
    destination_event_index = [event_index(2:end); ...
        chunk_report.start_event_index(chunk_i + 1)];
else
    source_event_index = event_index(1:end - 1);
    destination_event_index = event_index(2:end);
end

source_type = strip(string(event_table.type(source_event_index)));
destination_type = strip(string(event_table.type(destination_event_index)));
interval_sec = ( ...
    double(event_table.latency(destination_event_index)) - ...
    double(event_table.latency(source_event_index))) ./ Fs;
chunk_index = repmat(chunk_i, numel(source_event_index), 1);
edges = table( ...
    source_event_index, destination_event_index, source_type, ...
    destination_type, interval_sec, chunk_index);

end

%%
function edges = extract_canonical_edges(canonical_cycle)

source_type = strip(string(canonical_cycle.type));
destination_type = [source_type(2:end); source_type(1)];
interval_sec = double(canonical_cycle.interval_to_next_sec(:));
edges = table(source_type, destination_type, interval_sec);

end

%%
function interval_number = infer_canonical_interval_numbers( ...
    observed_edges, canonical_edges, tolerance_sec)

n_observed = height(observed_edges);
n_canonical = height(canonical_edges);
match_count = zeros(n_observed + 1, n_canonical + 1);
for observed_i = n_observed:-1:1
    for canonical_i = n_canonical:-1:1
        if single_edge_matches( ...
                observed_edges, observed_i, canonical_edges, canonical_i, ...
                tolerance_sec)
            match_count(observed_i, canonical_i) = ...
                match_count(observed_i + 1, canonical_i + 1) + 1;
        else
            match_count(observed_i, canonical_i) = max( ...
                match_count(observed_i + 1, canonical_i), ...
                match_count(observed_i, canonical_i + 1));
        end
    end
end

interval_number = nan(n_observed, 1);
observed_i = 1;
canonical_i = 1;
while observed_i <= n_observed && canonical_i <= n_canonical
    if single_edge_matches( ...
            observed_edges, observed_i, canonical_edges, canonical_i, ...
            tolerance_sec) && ...
            match_count(observed_i, canonical_i) == ...
                match_count(observed_i + 1, canonical_i + 1) + 1
        interval_number(observed_i) = canonical_i;
        observed_i = observed_i + 1;
        canonical_i = canonical_i + 1;
    elseif match_count(observed_i + 1, canonical_i) >= ...
            match_count(observed_i, canonical_i + 1)
        observed_i = observed_i + 1;
    else
        canonical_i = canonical_i + 1;
    end
end

end

%%
function [prefix_count, suffix_count] = matching_ends( ...
    observed_edges, canonical_edges, tolerance_sec)

prefix_count = matching_prefix_count( ...
    observed_edges, canonical_edges, tolerance_sec);
suffix_count = 0;
observed_i = height(observed_edges);
canonical_i = height(canonical_edges);
while observed_i > prefix_count && canonical_i >= 1 && ...
        single_edge_matches( ...
            observed_edges, observed_i, canonical_edges, canonical_i, ...
            tolerance_sec)
    suffix_count = suffix_count + 1;
    observed_i = observed_i - 1;
    canonical_i = canonical_i - 1;
end

end

%%
function prefix_count = matching_prefix_count( ...
    observed_edges, canonical_edges, tolerance_sec)

prefix_count = 0;
max_prefix_count = min(height(observed_edges), height(canonical_edges));
while prefix_count < max_prefix_count && single_edge_matches( ...
        observed_edges, prefix_count + 1, canonical_edges, ...
        prefix_count + 1, tolerance_sec)
    prefix_count = prefix_count + 1;
end

end

%%
function is_match = single_edge_matches( ...
    first_edges, first_i, second_edges, second_i, tolerance_sec)

types_match = ...
    first_edges.source_type(first_i) == second_edges.source_type(second_i) && ...
    first_edges.destination_type(first_i) == ...
        second_edges.destination_type(second_i);
comparison_scale = max([ ...
    abs(first_edges.interval_sec(first_i)), ...
    abs(second_edges.interval_sec(second_i)), 1]);
roundoff_tolerance_sec = 10 * eps(comparison_scale);
interval_matches = abs( ...
    first_edges.interval_sec(first_i) - ...
    second_edges.interval_sec(second_i)) <= ...
    tolerance_sec + roundoff_tolerance_sec;
is_match = types_match && interval_matches;

end

%%
function pairs = make_interval_pairs(eeg_edges, edf_edges, interval_number)

assert(height(eeg_edges) == height(edf_edges) && ...
    height(eeg_edges) == numel(interval_number), ...
    'Paired EEG/EDF interval lists must have equal lengths.')
pairs = table( ...
    eeg_edges.source_event_index, eeg_edges.destination_event_index, ...
    edf_edges.source_event_index, edf_edges.destination_event_index, ...
    eeg_edges.chunk_index, edf_edges.chunk_index, interval_number, ...
    'VariableNames', { ...
        'eeg_source_event_index', 'eeg_destination_event_index', ...
        'edf_source_event_index', 'edf_destination_event_index', ...
        'eeg_chunk_index', 'edf_chunk_index', 'interval_number'});

end

%%
function pairs = empty_interval_pair_table

pairs = table( ...
    zeros(0, 1), zeros(0, 1), zeros(0, 1), zeros(0, 1), ...
    zeros(0, 1), zeros(0, 1), zeros(0, 1), ...
    'VariableNames', { ...
        'eeg_source_event_index', 'eeg_destination_event_index', ...
        'edf_source_event_index', 'edf_destination_event_index', ...
        'eeg_chunk_index', 'edf_chunk_index', 'interval_number'});

end

%%
function validate_inputs(trigger_match_result, eeg_input, edf_input)

assert(isstruct(trigger_match_result) && ...
    isscalar(trigger_match_result) && ...
    istable(trigger_match_result.comparison_history), ...
    'trigger_match_result must be a scalar match_triggers result.')
assert(all(isfield(eeg_input, ...
    {'event_table', 'Fs', 'canonical_cycle', 'chunk_report'})), ...
    'eeg_input is missing fields returned by match_triggers.')
assert(all(isfield(edf_input, ...
    {'event_table', 'trigger_Fs', 'canonical_cycle', 'chunk_report'})), ...
    'edf_input is missing fields returned by match_triggers.')

end
