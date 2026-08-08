function figure_cleanup = save_and_track_alignment_figure( ...
    figure_handles, clinical_directory, subject_code, step_number, ...
    plot_descriptions)
%SAVE_AND_TRACK_ALIGNMENT_FIGURE Register cleanup and save figures.

figure_cleanup = onCleanup(@() close_valid_figures(figure_handles));
plot_descriptions = normalize_plot_descriptions(plot_descriptions);
if numel(plot_descriptions) ~= numel(figure_handles)
    error('save_and_track_alignment_figure:DescriptionCountMismatch', ...
        'Provide exactly one plot description for each figure handle.')
end

for figure_i = 1:numel(figure_handles)
    save_alignment_check_plot( ...
        figure_handles(figure_i), clinical_directory, subject_code, ...
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
