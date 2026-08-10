function figure_cleanup = save_and_track_alignment_figure( ...
    figure_handles, clinical_directory, subject_code, step_number, ...
    plot_descriptions)
%SAVE_AND_TRACK_ALIGNMENT_FIGURE Register cleanup and save figures.
%   Figures use a common 1600-by-900 pixel canvas before export.

figure_dimensions_pixels = [1600, 900];
figure_cleanup = onCleanup(@() close_valid_figures(figure_handles));
plot_descriptions = normalize_plot_descriptions(plot_descriptions);
if numel(plot_descriptions) ~= numel(figure_handles)
    error('save_and_track_alignment_figure:DescriptionCountMismatch', ...
        'Provide exactly one plot description for each figure handle.')
end

for figure_i = 1:numel(figure_handles)
    figure_handle = figure_handles(figure_i);
    figure_position = getpixelposition(figure_handle);
    figure_position(3:4) = figure_dimensions_pixels;
    setpixelposition(figure_handle, figure_position)
    drawnow
    save_alignment_check_plot( ...
        figure_handle, clinical_directory, subject_code, ...
        step_number, plot_descriptions{figure_i});
end

end

function plot_descriptions = normalize_plot_descriptions(plot_descriptions)

if ischar(plot_descriptions)
    plot_descriptions = {plot_descriptions};
elseif isstring(plot_descriptions)
    plot_descriptions = cellstr(plot_descriptions(:));
else
    plot_descriptions = plot_descriptions(:);
end

end

function close_valid_figures(figure_handles)

figure_handles = figure_handles(isgraphics(figure_handles, 'figure'));
if ~isempty(figure_handles)
    close(figure_handles)
end

end
