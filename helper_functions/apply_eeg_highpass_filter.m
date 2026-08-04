function filtered_eeg_data = apply_eeg_highpass_filter( ...
    centered_eeg_data, sampling_rate, progress_callback)
%APPLY_EEG_HIGHPASS_FILTER Apply the alignment high-pass to EEG channels.
%   Input rows are channels and columns are samples. The zero-phase filter
%   has an 80-dB stopband at 0.15 Hz and a 0.30-Hz passband edge.

if nargin < 3
    progress_callback = [];
end

stopband_Hz = 0.15;
passband_Hz = 0.30;
final_passband_loss_dB = 0.05;
final_stopband_attenuation_dB = 80;

% FILTFILT squares the one-pass magnitude response, thereby doubling its
% attenuation in dB. Design each pass for half of the final specification.
normalized_passband = passband_Hz / (sampling_rate / 2);
normalized_stopband = stopband_Hz / (sampling_rate / 2);
[filter_order, normalized_cutoff] = buttord( ...
    normalized_passband, normalized_stopband, ...
    final_passband_loss_dB / 2, ...
    final_stopband_attenuation_dB / 2);
[filter_zero, filter_pole, filter_gain] = butter( ...
    filter_order, normalized_cutoff, 'high');
[second_order_sections, scale_values] = zp2sos( ...
    filter_zero, filter_pole, filter_gain);

% Use second-order sections rather than direct-form coefficients because
% the normalized cutoff is very close to zero at approximately 500 Hz.
% Filtering one channel at a time also avoids transposing an hours-long
% multichannel array. Conservative edge effects can extend roughly 50-60
% seconds, depending on the endpoint signal and acceptable residual.
filtered_eeg_data = zeros(size(centered_eeg_data), 'double');
for channel_i = 1:size(centered_eeg_data, 1)
    if ~isempty(progress_callback)
        progress_callback(channel_i);
    end
    filtered_eeg_data(channel_i, :) = filtfilt( ...
        second_order_sections, scale_values, ...
        centered_eeg_data(channel_i, :));
end

end
