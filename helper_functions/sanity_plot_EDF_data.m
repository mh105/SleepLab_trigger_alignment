function figure_handle = sanity_plot_EDF_data( ...
    signalHeader_all, signalCell_all, trigger_data, edf_Fs, trigger_Fs)
%SANITY_PLOT_EDF_DATA Plot native clinical EDF and trigger channels.
%   The trigger, C3, M1, and E2 signals retain their native EDF sampling
%   grids and are shown on linked time axes over the full recording duration.

channel_names = {'C3', 'M1', 'E2'};
signal_labels = {signalHeader_all.signal_labels};
channel_data = cell(size(channel_names));
for channel_i = 1:numel(channel_names)
    channel_index = find(strcmp(signal_labels, channel_names{channel_i}));
    if isempty(channel_index)
        error('sanity_plot_EDF_data:MissingChannel', ...
            'Required EDF signal not found: %s.', channel_names{channel_i})
    elseif numel(channel_index) > 1
        error('sanity_plot_EDF_data:DuplicateChannel', ...
            'EDF signal occurs more than once: %s.', channel_names{channel_i})
    end
    channel_data{channel_i} = signalCell_all{channel_index}(:).';
end

trigger_data = trigger_data(:).';
channel_time_sec = cell(size(channel_names));
for channel_i = 1:numel(channel_names)
    channel_time_sec{channel_i} = ...
        (0:(numel(channel_data{channel_i}) - 1)) / edf_Fs;
end
trigger_time_sec = (0:(numel(trigger_data) - 1)) / trigger_Fs;

figure_handle = figure('Color', 'w');
layout_handle = tiledlayout(figure_handle, 7, 1, ...
    'TileSpacing', 'loose', ...
    'Padding', 'loose');
axes_handles = gobjects(4, 1);
axes_handles(1) = nexttile(layout_handle, 1);
axes_handles(2) = nexttile(layout_handle, 2, [2, 1]);
axes_handles(3) = nexttile(layout_handle, 4, [2, 1]);
axes_handles(4) = nexttile(layout_handle, 6, [2, 1]);

plot(axes_handles(1), trigger_time_sec, trigger_data, ...
    'LineWidth', 0.75, ...
    'DisplayName', 'EDF trigger channel');
ylabel(axes_handles(1), 'mV')
title(axes_handles(1), 'EDF trigger channel')

for channel_i = 1:numel(channel_names)
    axes_i = channel_i + 1;
    plot(axes_handles(axes_i), channel_time_sec{channel_i}, ...
        channel_data{channel_i}, ...
        'LineWidth', 0.75, ...
        'DisplayName', ['Clinical EDF ' channel_names{channel_i}])
    ylabel(axes_handles(axes_i), '\muV')
    title(axes_handles(axes_i), ['Clinical EDF ' channel_names{channel_i}])
end

for axes_i = 1:numel(axes_handles)
    axes_handles(axes_i).InteractionOptions.DatatipsSupported = 'off';
    grid(axes_handles(axes_i), 'on')
end

set(axes_handles, 'FontSize', 14)
set(axes_handles(1:3), 'XTickLabel', [])
linkaxes(axes_handles, 'x')
ylim(axes_handles(1), [-5, 45])
yticks(axes_handles(1), [0, 40])
set(axes_handles(2:4), 'YLim', [-1500, 1500])
end_times_sec = [trigger_time_sec(end), ...
    cellfun(@(time) time(end), channel_time_sec)];
xlim(axes_handles(1), [0, max(end_times_sec)])
xlabel(axes_handles(end), 'Time (sec)')
title(layout_handle, 'Clinical EDF trigger, C3, M1, and E2 channels', ...
    'FontSize', 18)

end
