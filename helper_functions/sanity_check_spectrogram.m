function figure_handle = sanity_check_spectrogram( ...
    EEG, header_final, signalHeader_final, signalCell_final)
%SANITY_CHECK_SPECTROGRAM Compare native and aligned C3:M2 spectrograms.
%   The native trace is constructed from the full 500-Hz recording by
%   mean-centering and high-pass filtering LA2 and RD6 separately, then
%   subtracting RD6 from LA2. The aligned trace is reconstructed from the
%   grounded EDF C3 and M2 rows. Subtracting the requantized clinical M2
%   from the prepared C3 row recovers the resampled and zero-padded
%   HD-EEG C3:M2 signal that the clinical montage will display.

native_channel_names = {'LA2', 'RD6'};
eeg_channel_names = {EEG.chanlocs.labels};
native_channel_index = zeros(size(native_channel_names));

for channel_i = 1:numel(native_channel_names)
    matching_index = find(strcmp( ...
        eeg_channel_names, native_channel_names{channel_i}));
    if isempty(matching_index)
        error('sanity_check_spectrogram:MissingNativeChannel', ...
            'Required native HD-EEG channel not found: %s.', ...
            native_channel_names{channel_i})
    elseif numel(matching_index) > 1
        error('sanity_check_spectrogram:DuplicateNativeChannel', ...
            'Native HD-EEG channel occurs more than once: %s.', ...
            native_channel_names{channel_i})
    end
    native_channel_index(channel_i) = matching_index;
end

native_channel_data = double(EEG.data(native_channel_index, :));
native_channel_data = native_channel_data - ...
    mean(native_channel_data, 2);
native_channel_data = apply_eeg_highpass_filter( ...
    native_channel_data, EEG.srate);
native_c3_m2 = native_channel_data(1, :) - ...
    native_channel_data(2, :);
clear native_channel_data

assert(numel(signalHeader_final) == numel(signalCell_final), ...
    'sanity_check_spectrogram:SignalCountMismatch', ...
    'The EDF signal header and signal cell counts must match.')
signal_labels = {signalHeader_final.signal_labels};
aligned_channel_names = {'C3', 'M2'};
aligned_channel_index = zeros(size(aligned_channel_names));

for channel_i = 1:numel(aligned_channel_names)
    matching_index = find(strcmp( ...
        signal_labels, aligned_channel_names{channel_i}));
    if isempty(matching_index)
        error('sanity_check_spectrogram:MissingAlignedChannel', ...
            'Required aligned EDF signal not found: %s.', ...
            aligned_channel_names{channel_i})
    elseif numel(matching_index) > 1
        error('sanity_check_spectrogram:DuplicateAlignedChannel', ...
            'Aligned EDF signal occurs more than once: %s.', ...
            aligned_channel_names{channel_i})
    end
    aligned_channel_index(channel_i) = matching_index;
end

aligned_c3 = signalCell_final{aligned_channel_index(1)};
clinical_m2 = signalCell_final{aligned_channel_index(2)};
assert(isvector(aligned_c3) && isvector(clinical_m2) && ...
    numel(aligned_c3) == numel(clinical_m2), ...
    'sanity_check_spectrogram:SampleCountMismatch', ...
    'Grounded EDF C3 and M2 must be vectors with equal sample counts.')
aligned_c3_m2 = double(aligned_c3(:)) - double(clinical_m2(:));

aligned_sampling_rates = ...
    [signalHeader_final(aligned_channel_index).samples_in_record] / ...
    header_final.data_record_duration;
assert(aligned_sampling_rates(1) == aligned_sampling_rates(2), ...
    'sanity_check_spectrogram:SamplingRateMismatch', ...
    'Grounded EDF C3 and M2 must have the same sampling rate.')
aligned_Fs = aligned_sampling_rates(1);

dfreqs = 0.1;
display_frequency_range = [0, 40];
mtm_taper_params = [2, 3];
mtm_window_params = [1, 0.05];
mtm_detrend = 'constant';
mtm_weighting = 'unity';
native_nfft = 2 ^ nextpow2(EEG.srate / dfreqs);
aligned_nfft = 2 ^ nextpow2(aligned_Fs / dfreqs);
native_mtm_window_params = mtm_window_params;
native_mtm_window_params(2) = ...
    ceil(mtm_window_params(2) * EEG.srate) / EEG.srate;
aligned_mtm_window_params = mtm_window_params;
aligned_mtm_window_params(2) = ...
    ceil(mtm_window_params(2) * aligned_Fs) / aligned_Fs;

figure_handle = figure( ...
    'Name', 'C3:M2 spectrogram sanity check', ...
    'Tag', 'sanity_check_spectrogram', ...
    'Color', 'w');
axes_handles = gobjects(2, 1);

[native_spectrogram, native_stimes, native_sfreqs] = ...
    multitaper_spectrogram_mex(native_c3_m2, EEG.srate, ...
    display_frequency_range, mtm_taper_params, ...
    native_mtm_window_params, ...
    native_nfft, mtm_detrend, mtm_weighting, false, false);
clear native_c3_m2

axes_handles(1) = subplot(2, 1, 1, 'Parent', figure_handle);
imagesc(axes_handles(1), native_stimes / 3600, native_sfreqs, ...
    pow2db(native_spectrogram))
clear native_spectrogram
axis(axes_handles(1), 'xy')
axis(axes_handles(1), 'tight')
xlabel(axes_handles(1), 'Time from HD-EEG recording start (hours)')
ylabel(axes_handles(1), 'Frequency (Hz)')
title(axes_handles(1), sprintf( ...
    'Original HD-EEG C3:M2 (LA2 - RD6), %.0f Hz', EEG.srate))
native_color_limits = climscale(axes_handles(1));
native_colorbar = colorbar(axes_handles(1));
ylabel(native_colorbar, 'PSD (dB)')

[aligned_spectrogram, aligned_stimes, aligned_sfreqs] = ...
    multitaper_spectrogram_mex(aligned_c3_m2, aligned_Fs, ...
    display_frequency_range, mtm_taper_params, ...
    aligned_mtm_window_params, ...
    aligned_nfft, mtm_detrend, mtm_weighting, false, false);

axes_handles(2) = subplot(2, 1, 2, 'Parent', figure_handle);
imagesc(axes_handles(2), aligned_stimes / 3600, aligned_sfreqs, ...
    pow2db(aligned_spectrogram))
clear aligned_spectrogram
axis(axes_handles(2), 'xy')
axis(axes_handles(2), 'tight')
xlabel(axes_handles(2), 'Time on EDF clock (hours)')
ylabel(axes_handles(2), 'Frequency (Hz)')
title(axes_handles(2), sprintf( ...
    ['Grounded EDF C3 - M2 (aligned and zero-padded), ' ...
     '%.0f Hz'], aligned_Fs))
aligned_color_limits = climscale(axes_handles(2));
aligned_colorbar = colorbar(axes_handles(2));
ylabel(aligned_colorbar, 'PSD (dB)')

shared_color_limits = [ ...
    min(native_color_limits(1), aligned_color_limits(1)), ...
    max(native_color_limits(2), aligned_color_limits(2))];
set(axes_handles, 'CLim', shared_color_limits, 'FontSize', 16)
set(axes_handles(1), 'Tag', 'sanity_check_spectrogram_native_axes')
set(axes_handles(2), 'Tag', 'sanity_check_spectrogram_aligned_axes')
colormap(figure_handle, 'jet')
linkaxes(axes_handles, 'y')
ylim(axes_handles(1), display_frequency_range)
sgtitle(figure_handle, 'Native and aligned C3:M2 spectrograms', ...
    'FontSize', 18)

end
