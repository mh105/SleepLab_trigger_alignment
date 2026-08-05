function tests = test_sanity_plot_EDF_data
tests = functiontests(localfunctions);
end

function setupOnce(~)
project_path = fileparts(fileparts(mfilename('fullpath')));
addpath(project_path)
addpath(fullfile(project_path, 'helper_functions'))
end

function testPlotsC3AndTriggerOnTheirNativeSampleGrids(testCase)
c3_data = [1; 2; 3; 4; 5];
trigger_data = [10, 20, 30];
edf_Fs = 2;
trigger_Fs = 1;

original_visibility = get(groot, 'defaultFigureVisible');
visibility_cleanup = onCleanup(@() set( ...
    groot, 'defaultFigureVisible', original_visibility));
set(groot, 'defaultFigureVisible', 'off')

figure_handle = sanity_plot_EDF_data( ...
    c3_data, trigger_data, edf_Fs, trigger_Fs);
figure_cleanup = onCleanup(@() delete(figure_handle));

verifyEmpty(testCase, figure_handle.Name)
verifyEmpty(testCase, figure_handle.Tag)
verifyEqual(testCase, figure_handle.Color, [1, 1, 1])

axes_handle = findall(figure_handle, 'Type', 'axes');
verifyNumElements(testCase, axes_handle, 1)
verifyEqual(testCase, axes_handle.FontSize, 14)
verifyEqual(testCase, axes_handle.Title.FontSize, 18)
verifyEqual(testCase, ...
    char(axes_handle.InteractionOptions.DatatipsSupported), 'off')
verifyEqual(testCase, ...
    char(axes_handle.InteractionOptions.ZoomSupported), 'on')

c3_line = findall(figure_handle, 'Type', 'line', ...
    'DisplayName', 'Clinical EDF C3');
trigger_line = findall(figure_handle, 'Type', 'line', ...
    'DisplayName', 'EDF trigger channel');
verifyNumElements(testCase, c3_line, 1)
verifyNumElements(testCase, trigger_line, 1)
verifyEqual(testCase, c3_line.XData, (0:4) / edf_Fs)
verifyEqual(testCase, c3_line.YData, c3_data(:).')
verifyEqual(testCase, trigger_line.XData, (0:2) / trigger_Fs)
verifyEqual(testCase, trigger_line.YData, trigger_data(:).')
verifyEqual(testCase, axes_handle.XLim, [0, 2])
verifyEqual(testCase, string(axes_handle.XLabel.String), "Time (sec)")
end
