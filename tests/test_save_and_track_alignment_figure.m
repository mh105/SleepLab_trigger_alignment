function tests = test_save_and_track_alignment_figure
tests = functiontests(localfunctions);
end

function setupOnce(~)
project_path = fileparts(fileparts(mfilename('fullpath')));
addpath(fullfile(project_path, 'helper_functions'))
end

function testSavesExpectedPng(testCase)
[output_directory, directory_cleanup] = make_temp_directory; %#ok<ASGLU>
figure_handle = make_hidden_figure(1);
setpixelposition(figure_handle, [100, 100, 400, 300])
figure_cleanup = save_and_track_alignment_figure( ...
    figure_handle, output_directory, 'sas_041', 8, ...
    'scalp_substitution');
verifyClass(testCase, figure_cleanup, 'onCleanup')
figure_position = getpixelposition(figure_handle);
verifyEqual(testCase, figure_position(3:4), [1600, 900])

expected_file = fullfile(output_directory, ...
    'sas_041_alignment_check_step8_scalp_substitution.png');
verifyTrue(testCase, isfile(expected_file))
verifyGreaterThan(testCase, dir(expected_file).bytes, 0)
image_info = imfinfo(expected_file);
verifyEqual(testCase, lower(string(image_info(1).Format)), "png")
verifyTrue(testCase, isgraphics(figure_handle, 'figure'))

clear figure_cleanup
end

function testCleanupClosesOnlyTrackedFigures(testCase)
[output_directory, directory_cleanup] = make_temp_directory; %#ok<ASGLU>
tracked_figures = [make_hidden_figure(1), make_hidden_figure(2)];
setpixelposition(tracked_figures(1), [100, 100, 500, 400])
setpixelposition(tracked_figures(2), [100, 100, 700, 500])
unrelated_figure = make_hidden_figure(3);
remaining_figure_cleanup = onCleanup( ...
    @() delete_figures([tracked_figures, unrelated_figure]));
verifyClass(testCase, remaining_figure_cleanup, 'onCleanup')

figure_cleanup = save_and_track_alignment_figure( ...
    tracked_figures, output_directory, 'sas_042', 6, ...
    {'seg01_1_trace', 'seg01_2_spectrum'});
verifyClass(testCase, figure_cleanup, 'onCleanup')
verifyTrue(testCase, all(isgraphics(tracked_figures, 'figure')))
verifyTrue(testCase, isgraphics(unrelated_figure, 'figure'))
for figure_i = 1:numel(tracked_figures)
    figure_position = getpixelposition(tracked_figures(figure_i));
    verifyEqual(testCase, figure_position(3:4), [1600, 900])
end

clear figure_cleanup

verifyFalse(testCase, any(isgraphics(tracked_figures, 'figure')))
verifyTrue(testCase, isgraphics(unrelated_figure, 'figure'))
end

function testLaterSaveFailureClosesAllTrackedFigures(testCase)
[output_directory, directory_cleanup] = make_temp_directory; %#ok<ASGLU>
tracked_figures = [make_hidden_figure(1), make_hidden_figure(2)];
unrelated_figure = make_hidden_figure(3);
remaining_figure_cleanup = onCleanup( ...
    @() delete_figures([tracked_figures, unrelated_figure]));
verifyClass(testCase, remaining_figure_cleanup, 'onCleanup')

caught_exception = [];
try
    save_and_track_alignment_figure( ...
        tracked_figures, output_directory, 'sas_042', 6, ...
        {'seg01_1_trace', 'missing/seg01_2_spectrum'});
catch caught_exception
end

verifyNotEmpty(testCase, caught_exception)
verifyTrue(testCase, isfile(fullfile(output_directory, ...
    'sas_042_alignment_check_step6_seg01_1_trace.png')))
verifyFalse(testCase, any(isgraphics(tracked_figures, 'figure')))
verifyTrue(testCase, isgraphics(unrelated_figure, 'figure'))
end

function figure_handle = make_hidden_figure(scale)

figure_handle = figure('Visible', 'off', 'Color', 'w');
axes_handle = axes('Parent', figure_handle);
plot(axes_handle, 0:2, scale .* [0, 1, 0])

end

function [output_directory, directory_cleanup] = make_temp_directory

output_directory = tempname;
mkdir(output_directory)
directory_cleanup = onCleanup( ...
    @() remove_temp_directory(output_directory));

end

function remove_temp_directory(output_directory)

if isfolder(output_directory)
    rmdir(output_directory, 's')
end

end

function delete_figures(figure_handles)

figure_handles = figure_handles(isgraphics(figure_handles, 'figure'));
if ~isempty(figure_handles)
    delete(figure_handles)
end

end
