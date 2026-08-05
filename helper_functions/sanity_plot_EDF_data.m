function figure_handle = sanity_plot_EDF_data( ...
    c3_data, trigger_data, edf_Fs, trigger_Fs)
%SANITY_PLOT_EDF_DATA Compare native clinical EDF C3 and trigger channels.
%   The two signals retain their native EDF sampling grids and are shown on
%   separate y-axes over the full recording duration.

c3_data = c3_data(:).';
trigger_data = trigger_data(:).';
c3_time_sec = (0:(numel(c3_data) - 1)) / edf_Fs;
trigger_time_sec = (0:(numel(trigger_data) - 1)) / trigger_Fs;

figure_handle = figure('Color', 'w');
axes_handle = axes('Parent', figure_handle);

yyaxis(axes_handle, 'left')
c3_line = plot(axes_handle, c3_time_sec, c3_data, ...
    'LineWidth', 0.75, ...
    'DisplayName', 'Clinical EDF C3');
ylabel(axes_handle, 'C3 voltage (\muV)')

yyaxis(axes_handle, 'right')
trigger_line = plot(axes_handle, trigger_time_sec, trigger_data, ...
    'LineWidth', 0.75, ...
    'DisplayName', 'EDF trigger channel');
ylabel(axes_handle, 'Trigger amplitude')

axes_handle.InteractionOptions.DatatipsSupported = 'off';
set(axes_handle, 'FontSize', 14)
xlim(axes_handle, [0, max(c3_time_sec(end), trigger_time_sec(end))])
xlabel(axes_handle, 'Time (sec)')
title(axes_handle, 'Clinical EDF C3 and trigger channel', ...
    'FontSize', 18)
legend(axes_handle, [c3_line, trigger_line], 'Location', 'best')
grid(axes_handle, 'on')

end
