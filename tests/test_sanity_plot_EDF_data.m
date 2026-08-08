function tests = test_sanity_plot_EDF_data
tests = functiontests(localfunctions);
end

function setupOnce(~)
project_path = fileparts(fileparts(mfilename('fullpath')));
addpath(project_path)
addpath(fullfile(project_path, 'helper_functions'))
end

function testPlotsClinicalChannelsAndTriggerOnLinkedNativeGrids(testCase)
signalHeader_all = struct('signal_labels', ...
    {'M1', 'Decoy', 'E2', 'C3'});
signalCell_all = { ...
    [11, 12, 13, 14], ...
    [100, 200], ...
    [21; 22; 23; 24; 25; 26], ...
    [1; 2; 3; 4; 5]};
trigger_data = [10, 20, 30];
edf_Fs = 2;
trigger_Fs = 1;

original_visibility = get(groot, 'defaultFigureVisible');
visibility_cleanup = onCleanup(@() set( ...
    groot, 'defaultFigureVisible', original_visibility));
set(groot, 'defaultFigureVisible', 'off')

figure_handle = sanity_plot_EDF_data( ...
    signalHeader_all, signalCell_all, trigger_data, edf_Fs, trigger_Fs);
figure_cleanup = onCleanup(@() delete(figure_handle));

verifyEmpty(testCase, figure_handle.Name)
verifyEmpty(testCase, figure_handle.Tag)
verifyEqual(testCase, figure_handle.Color, [1, 1, 1])

axes_handles = findall(figure_handle, 'Type', 'axes');
verifyNumElements(testCase, axes_handles, 4)

display_names = { ...
    'EDF trigger channel', ...
    'Clinical EDF C3', ...
    'Clinical EDF M1', ...
    'Clinical EDF E2'};
expected_data = { ...
    trigger_data, ...
    signalCell_all{4}, ...
    signalCell_all{1}, ...
    signalCell_all{3}};
expected_Fs = [trigger_Fs, edf_Fs, edf_Fs, edf_Fs];
ordered_axes = gobjects(4, 1);

for plot_i = 1:numel(display_names)
    line_handle = findall(figure_handle, 'Type', 'line', ...
        'DisplayName', display_names{plot_i});
    verifyNumElements(testCase, line_handle, 1)
    verifyEqual(testCase, line_handle.XData, ...
        (0:(numel(expected_data{plot_i}) - 1)) / expected_Fs(plot_i))
    verifyEqual(testCase, line_handle.YData, expected_data{plot_i}(:).')

    ordered_axes(plot_i) = ancestor(line_handle, 'axes');
    verifyEqual(testCase, ordered_axes(plot_i).FontSize, 14)
    verifyEqual(testCase, ...
        char(ordered_axes(plot_i).InteractionOptions.DatatipsSupported), ...
        'off')
    verifyEqual(testCase, ...
        char(ordered_axes(plot_i).InteractionOptions.ZoomSupported), 'on')
end

verifyEqual(testCase, ordered_axes(1).YLim, [-5, 45])
verifyEqual(testCase, string(ordered_axes(1).YLabel.String), "mV")
for axes_i = 2:4
    verifyEqual(testCase, ordered_axes(axes_i).YLim, [-1500, 1500])
    verifyEqual(testCase, string(ordered_axes(axes_i).YLabel.String), "\muV")
end

verifyGreaterThan(testCase, ordered_axes(1).Position(2), ...
    ordered_axes(2).Position(2))
verifyGreaterThan(testCase, ordered_axes(2).Position(2), ...
    ordered_axes(3).Position(2))
verifyGreaterThan(testCase, ordered_axes(3).Position(2), ...
    ordered_axes(4).Position(2))
verifyLessThan(testCase, ordered_axes(1).Position(4), ...
    min(arrayfun(@(ax) ax.Position(4), ordered_axes(2:4))))
vertical_gaps = arrayfun(@(upper_ax, lower_ax) ...
    upper_ax.Position(2) - ...
    (lower_ax.Position(2) + lower_ax.Position(4)), ...
    ordered_axes(1:3), ordered_axes(2:4));
verifyGreaterThan(testCase, min(vertical_gaps), 0.05)

verifyEqual(testCase, ordered_axes(1).XLim, [0, 2.5])
xlim(ordered_axes(1), [0.25, 1.5])
for axes_i = 1:numel(ordered_axes)
    verifyEqual(testCase, ordered_axes(axes_i).XLim, [0.25, 1.5])
end
verifyEqual(testCase, ...
    string(ordered_axes(end).XLabel.String), "Time (sec)")
end
