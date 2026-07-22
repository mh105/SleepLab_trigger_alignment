function figure_handle = sanity_check_spectrogram( ...
    EEG, header_final, signalHeader_final, signalCell_final)
%SANITY_CHECK_SPECTROGRAM Compare native and aligned C3:M2 spectrograms.
%   The native trace is constructed from the full 500-Hz recording by
%   mean-centering and high-pass filtering LA2 and RD6 separately, then
%   subtracting RD6 from LA2. The aligned trace is read directly from the
%   substituted, resampled, and zero-padded EDF C3:M2 signal.

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
c3_m2_index = find(strcmp(signal_labels, 'C3:M2'));
if isempty(c3_m2_index)
    error('sanity_check_spectrogram:MissingAlignedChannel', ...
        'Required aligned EDF signal not found: C3:M2.')
elseif numel(c3_m2_index) > 1
    error('sanity_check_spectrogram:DuplicateAlignedChannel', ...
        'Aligned EDF signal occurs more than once: C3:M2.')
end

aligned_c3_m2 = signalCell_final{c3_m2_index};
aligned_Fs = ...
    signalHeader_final(c3_m2_index).samples_in_record / ...
    header_final.data_record_duration;

dfreqs = 0.1;
display_frequency_range = [0, 40];
mtm_taper_params = [2, 3];
mtm_window_params = [1, 0.05];
mtm_detrend = 'constant';
mtm_weighting = 'unity';
native_nfft = 2 ^ nextpow2(EEG.srate / dfreqs);
aligned_nfft = 2 ^ nextpow2(aligned_Fs / dfreqs);

figure_handle = figure( ...
    'Name', 'C3:M2 spectrogram sanity check', ...
    'Tag', 'sanity_check_spectrogram', ...
    'Color', 'w');
axes_handles = gobjects(2, 1);

[native_spectrogram, native_stimes, native_sfreqs] = ...
    multitaper_spectrogram_mex(native_c3_m2, EEG.srate, ...
    display_frequency_range, mtm_taper_params, mtm_window_params, ...
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
    display_frequency_range, mtm_taper_params, mtm_window_params, ...
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
    ['Aligned, resampled, and zero-padded C3:M2, ' ...
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
