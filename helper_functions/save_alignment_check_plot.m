function output_file = save_alignment_check_plot( ...
    figure_handle, output_directory, subject_code, step_number, suffix)
%SAVE_ALIGNMENT_CHECK_PLOT Export one alignment sanity-check figure as PNG.

if nargin < 5
    suffix = '';
end

subject_code = char(string(subject_code));
suffix = char(string(suffix));
if isempty(suffix)
    filename = sprintf( ...
        '%s_alignment_check_step%d.png', subject_code, step_number);
else
    filename = sprintf( ...
        '%s_alignment_check_step%d_%s.png', ...
        subject_code, step_number, suffix);
end

output_file = fullfile(output_directory, filename);
exportgraphics(figure_handle, output_file)

end
