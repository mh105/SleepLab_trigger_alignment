function tests = test_save_alignment_check_plot
tests = functiontests(localfunctions);
end

function setupOnce(~)
project_path = fileparts(fileparts(mfilename('fullpath')));
addpath(fullfile(project_path, 'helper_functions'))
end

function testSavesStepWithoutSuffix(testCase)
[output_directory, directory_cleanup] = make_temp_directory; %#ok<ASGLU>
figure_handle = make_hidden_figure(1);
figure_cleanup = onCleanup(@() delete_figures(figure_handle));

output_file = save_alignment_check_plot( ...
    figure_handle, output_directory, 'sas_017', 3);
expected_basename = 'sas_017_alignment_check_step3.png';
expected_file = fullfile(output_directory, expected_basename);

verifyEqual(testCase, output_file, expected_file)
verify_png(testCase, output_file)
verifyTrue(testCase, isgraphics(figure_handle))
verifyEqual(testCase, png_basenames(output_directory), ...
    string(expected_basename))
end

function testSavesMultiplePlotsWithinStepWithSuffixes(testCase)
[output_directory, directory_cleanup] = make_temp_directory; %#ok<ASGLU>
figure_handles = gobjects(2, 1);
figure_handles(1) = make_hidden_figure(1);
figure_handles(2) = make_hidden_figure(2);
figure_cleanup = onCleanup( ...
    @() delete_figures(figure_handles));

trace_file = save_alignment_check_plot( ...
    figure_handles(1), output_directory, ...
    'sas_017', 6, 'seg2_trace');
spectrum_file = save_alignment_check_plot( ...
    figure_handles(2), output_directory, ...
    'sas_017', 6, 'seg2_spect');
expected_basenames = [ ...
    "sas_017_alignment_check_step6_seg2_trace.png"; ...
    "sas_017_alignment_check_step6_seg2_spect.png"];

verifyEqual(testCase, trace_file, ...
    fullfile(output_directory, char(expected_basenames(1))))
verifyEqual(testCase, spectrum_file, ...
    fullfile(output_directory, char(expected_basenames(2))))
verify_png(testCase, trace_file)
verify_png(testCase, spectrum_file)
verifyTrue(testCase, all(isgraphics(figure_handles)))
verifyEqual(testCase, png_basenames(output_directory), ...
    sort(expected_basenames))
end

function figure_handle = make_hidden_figure(scale)

figure_handle = figure('Visible', 'off', 'Color', 'w');
axes_handle = axes('Parent', figure_handle);
plot(axes_handle, 0:2, scale .* [0, 1, 0])

end

function verify_png(testCase, output_file)

verifyTrue(testCase, isfile(output_file))
file_listing = dir(output_file);
verifyNumElements(testCase, file_listing, 1)
verifyGreaterThan(testCase, file_listing.bytes, 0)
image_info = imfinfo(output_file);
verifyFalse(testCase, isempty(image_info))
verifyEqual(testCase, lower(string(image_info(1).Format)), "png")

end

function basenames = png_basenames(output_directory)

file_listing = dir(fullfile(output_directory, '*.png'));
basenames = sort(string({file_listing.name}).');

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

figure_handles = figure_handles(isgraphics(figure_handles));
if ~isempty(figure_handles)
    delete(figure_handles)
end

end
