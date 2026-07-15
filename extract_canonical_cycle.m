function [canonical_cycle, repeat_count, chunk_report] = ...
    extract_canonical_cycle(event_table, Fs, interval_tolerance_sec)
%EXTRACT_CANONICAL_CYCLE Infer the recurring nightly trigger cycle.
%   [CANONICAL_CYCLE, REPEAT_COUNT, CHUNK_REPORT] = ...
%       EXTRACT_CANONICAL_CYCLE(EVENT_TABLE, FS, INTERVAL_TOLERANCE_SEC)
%   segments triggers at intact runs of four 64 events and selects the most
%   frequently repeated bounded-cycle structure. Trigger latencies must be
%   sample points, and EVENT_TABLE must contain latency and type variables.

assert(istable(event_table), 'event_table must be a table.')
required_variables = ["latency", "type"];
variable_names = string(event_table.Properties.VariableNames);
assert(all(ismember(required_variables, variable_names)), ...
    'event_table must contain latency and type variables.')
assert(isnumeric(Fs) && isscalar(Fs) && isfinite(Fs) && Fs > 0, ...
    'Fs must be a positive finite scalar.')
assert(isnumeric(interval_tolerance_sec) && ...
    isscalar(interval_tolerance_sec) && ...
    isfinite(interval_tolerance_sec) && interval_tolerance_sec >= 0, ...
    'interval_tolerance_sec must be a nonnegative finite scalar.')
assert(isnumeric(event_table.latency), ...
    'event_table.latency must contain numeric sample points.')

latency = double(event_table.latency(:));
trigger_type = strip(string(event_table.type(:)));

assert(~isempty(latency), 'event_table must contain at least one trigger.')
assert(all(isfinite(latency)) && all(diff(latency) > 0), ...
    'event_table.latency must be finite and strictly increasing.')
assert(~any(ismissing(trigger_type)), ...
    'event_table.type must not contain missing values.')
assert(all(ismember(trigger_type, ["63"; "64"])), ...
    'event_table.type must contain only 63 and 64 triggers.')

%% Use intact runs of four 64 triggers as observed cycle boundaries
is64 = trigger_type == "64";
run_edges = diff([false; is64; false]);
run_start = find(run_edges == 1);
run_end = find(run_edges == -1) - 1;
run_length = run_end - run_start + 1;

assert(~isempty(run_start), ...
    'No run of 64 triggers was found.')
assert(all(run_length == 4), ...
    ['All retained 64 triggers must occur in runs of four. ' ...
     'Remove incomplete 64 runs before calling this function.'])

boundary_start = run_start;
assert(boundary_start(1) == 1, ...
    'The first four events must be the initial 64-trigger boundary.')
assert(numel(boundary_start) >= 3, ...
    ['At least three intact 64-trigger boundaries are required to ' ...
     'identify a repeated bounded-cycle structure.'])

n_chunks = numel(boundary_start);
n_bounded_chunks = n_chunks - 1;
chunk_end = [boundary_start(2:end) - 1; height(event_table)];

chunk_type = cell(n_chunks, 1);
chunk_interval_sec = cell(n_chunks, 1);
chunk_duration_sec = nan(n_chunks, 1);

for chunk_i = 1:n_chunks
    event_rows = boundary_start(chunk_i):chunk_end(chunk_i);
    event_time_sec = latency(event_rows) ./ Fs;
    chunk_type{chunk_i} = trigger_type(event_rows);

    if chunk_i <= n_bounded_chunks
        next_boundary_time_sec = latency(boundary_start(chunk_i + 1)) ./ Fs;
        chunk_interval_sec{chunk_i} = diff([event_time_sec; next_boundary_time_sec]);
        chunk_duration_sec(chunk_i) = next_boundary_time_sec - event_time_sec(1);
    else
        chunk_interval_sec{chunk_i} = diff(event_time_sec);
        chunk_duration_sec(chunk_i) = event_time_sec(end) - event_time_sec(1);
    end
end

%% Find the most frequently repeated bounded-cycle structure
is_compatible = false(n_bounded_chunks);
for chunk_i = 1:n_bounded_chunks
    for comparison_i = chunk_i:n_bounded_chunks
        is_match = cycles_match( ...
            chunk_type{chunk_i}, chunk_interval_sec{chunk_i}, ...
            chunk_type{comparison_i}, chunk_interval_sec{comparison_i}, ...
            interval_tolerance_sec);
        is_compatible(chunk_i, comparison_i) = is_match;
        is_compatible(comparison_i, chunk_i) = is_match;
    end
end

support_count = sum(is_compatible, 2);
max_support = max(support_count);
assert(max_support >= 2, ...
    ['No bounded-cycle structure repeats at least twice. ' ...
     'A canonical cycle cannot be identified reliably.'])

top_candidate_mask = support_count == max_support;
reference_chunk = find(top_candidate_mask, 1, 'first');
if any(~is_compatible(reference_chunk, top_candidate_mask))
    error('extract_canonical_cycle:AmbiguousCanonicalCycle', ...
        ['Multiple distinct bounded-cycle structures are tied for most ' ...
         'frequent. A canonical cycle cannot be selected uniquely.'])
end

bounded_chunk_interval_sec = chunk_interval_sec(1:n_bounded_chunks);
canonical_member_mask = is_compatible(reference_chunk, :)';
canonical_interval_matrix = cell2mat(cellfun( ...
    @(x) x(:)', bounded_chunk_interval_sec(canonical_member_mask), ...
    'UniformOutput', false));
canonical_interval_sec = median(canonical_interval_matrix, 1)';
canonical_type = chunk_type{reference_chunk};

first_63_index = find(canonical_type == "63", 1, 'first');
assert(~isempty(first_63_index), ...
    'The selected canonical cycle does not contain a 63 trigger.')

canonical_relative_time_sec = [0; cumsum(canonical_interval_sec(1:end - 1))];
canonical_relative_time_sec = ...
    canonical_relative_time_sec - canonical_relative_time_sec(first_63_index);

canonical_cycle = table( ...
    canonical_type, canonical_relative_time_sec, canonical_interval_sec, ...
    'VariableNames', {'type', 'relative_time_sec', 'interval_to_next_sec'});
canonical_duration_sec = sum(canonical_interval_sec);

%% Compare every observed chunk with the canonical cycle
chunk_index = (1:n_chunks)';
start_event_index = boundary_start;
end_event_index = chunk_end;
start_latency = latency(boundary_start);
start_time_sec = start_latency ./ Fs;
observed_trigger_count = chunk_end - boundary_start + 1;
has_next_boundary = chunk_index <= n_bounded_chunks;
status = strings(n_chunks, 1);
reason = strings(n_chunks, 1);
max_interval_error_sec = nan(n_chunks, 1);
estimated_cycle_count = nan(n_chunks, 1);
estimated_cycle_count(has_next_boundary) = max(1, round( ...
    chunk_duration_sec(has_next_boundary) ./ canonical_duration_sec));

for chunk_i = 1:n_chunks
    expected_interval_sec = canonical_interval_sec;
    if ~has_next_boundary(chunk_i)
        expected_interval_sec = expected_interval_sec(1:end - 1);
    end

    [is_match, max_error, mismatch_reason] = compare_cycle( ...
        chunk_type{chunk_i}, chunk_interval_sec{chunk_i}, ...
        canonical_type, expected_interval_sec, interval_tolerance_sec);
    max_interval_error_sec(chunk_i) = max_error;

    if is_match
        status(chunk_i) = "match";
        if ~has_next_boundary(chunk_i)
            reason(chunk_i) = "next_boundary_not_observed";
        end
    elseif has_next_boundary(chunk_i)
        if estimated_cycle_count(chunk_i) > 1
            status(chunk_i) = "ambiguous";
            reason(chunk_i) = "suspected_missing_boundary";
        else
            status(chunk_i) = "mismatch";
            reason(chunk_i) = mismatch_reason;
        end
    else
        status(chunk_i) = "partial_end";
        reason(chunk_i) = mismatch_reason;
    end
end

repeat_count = sum(status == "match");

chunk_report = table( ...
    chunk_index, start_event_index, end_event_index, start_latency, ...
    start_time_sec, observed_trigger_count, chunk_duration_sec, ...
    has_next_boundary, estimated_cycle_count, status, reason, ...
    max_interval_error_sec);

end

function is_match = cycles_match( ...
    observed_type, observed_interval_sec, ...
    expected_type, expected_interval_sec, tolerance_sec)

[is_match, ~] = compare_cycle( ...
    observed_type, observed_interval_sec, ...
    expected_type, expected_interval_sec, tolerance_sec);

end

function [is_match, max_error_sec, reason] = compare_cycle( ...
    observed_type, observed_interval_sec, ...
    expected_type, expected_interval_sec, tolerance_sec)

if numel(observed_type) ~= numel(expected_type) || ...
        numel(observed_interval_sec) ~= numel(expected_interval_sec) || ...
        ~isequal(observed_type, expected_type)
    is_match = false;
    max_error_sec = NaN;
    reason = "count_or_type";
    return
end

interval_error_sec = abs(observed_interval_sec - expected_interval_sec);
max_error_sec = max(interval_error_sec, [], 'omitnan');
comparison_scale = max([abs(observed_interval_sec(:)); ...
    abs(expected_interval_sec(:)); 1]);
roundoff_tolerance_sec = 10 * eps(comparison_scale);
is_match = all(interval_error_sec <= tolerance_sec + roundoff_tolerance_sec);

if is_match
    reason = "";
else
    reason = "interval_timing";
end

end
