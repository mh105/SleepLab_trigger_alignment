function tests = test_sanity_check_spectrogram
tests = functiontests(localfunctions);
end

function setupOnce(~)
project_path = fileparts(fileparts(mfilename('fullpath')));
addpath(project_path)
addpath(fullfile(project_path, 'helper_functions'))
addpath(fullfile(getenv('HOME'), 'Dropbox', 'Active_projects', ...
    'EEG', 'code', 'sleepeeg_code', 'helper_functions'))
end

function testPlotsNativeAndAlignedSpectrogramsWithSharedScales(testCase)
[EEG, header_final, signalHeader_final, signalCell_final] = ...
    make_fixture;

original_visibility = get(groot, 'defaultFigureVisible');
visibility_cleanup = onCleanup(@() set( ...
    groot, 'defaultFigureVisible', original_visibility));
set(groot, 'defaultFigureVisible', 'off')

figures_before = findall(groot, 'Type', 'figure');
verifyWarningFree(testCase, @() sanity_check_spectrogram( ...
    EEG, header_final, signalHeader_final, signalCell_final))
figures_after = findall(groot, 'Type', 'figure');
new_figures = setdiff(figures_after, figures_before);
figure_handle = findobj( ...
    new_figures, 'flat', 'Tag', 'sanity_check_spectrogram');
figure_cleanup = onCleanup(@() delete(figure_handle));

verifyNumElements(testCase, new_figures, 1)
verifyNumElements(testCase, figure_handle, 1)
verifyEqual(testCase, figure_handle.Tag, ...
    'sanity_check_spectrogram')
native_axes = findall(figure_handle, 'Type', 'axes', ...
    'Tag', 'sanity_check_spectrogram_native_axes');
aligned_axes = findall(figure_handle, 'Type', 'axes', ...
    'Tag', 'sanity_check_spectrogram_aligned_axes');
verifyNumElements(testCase, native_axes, 1)
verifyNumElements(testCase, aligned_axes, 1)
verifyGreaterThan(testCase, native_axes.Position(2), ...
    aligned_axes.Position(2))
verifyEqual(testCase, native_axes.YLim, [0, 40], 'AbsTol', 1e-12)
verifyEqual(testCase, aligned_axes.YLim, [0, 40], 'AbsTol', 1e-12)
verifyEqual(testCase, native_axes.CLim, aligned_axes.CLim, ...
    'AbsTol', 1e-12)
verifyTrue(testCase, all(isfinite(native_axes.CLim)))
verifyGreaterThan(testCase, native_axes.CLim(2), native_axes.CLim(1))

native_image = findall(native_axes, 'Type', 'image');
aligned_image = findall(aligned_axes, 'Type', 'image');
verifyNumElements(testCase, native_image, 1)
verifyNumElements(testCase, aligned_image, 1)
verifySize(testCase, native_image.CData, [656, 61])
verifySize(testCase, aligned_image.CData, [641, 60])

native_nfft = 2 ^ nextpow2(EEG.srate / 0.1);
native_df = EEG.srate / native_nfft;
native_median_spectrum = median(native_image.CData, 2);
c3_tone_index = round(10 / native_df) + 1;
m2_tone_index = round(3 / native_df) + 1;
background_index = round(20 / native_df) + 1;
verifyGreaterThan(testCase, ...
    native_median_spectrum(c3_tone_index), ...
    native_median_spectrum(background_index) + 10)
verifyGreaterThan(testCase, ...
    native_median_spectrum(m2_tone_index), ...
    native_median_spectrum(background_index) + 5)

aligned_nfft = 2 ^ nextpow2(256 / 0.1);
aligned_df = 256 / aligned_nfft;
aligned_median_spectrum = median(aligned_image.CData, 2);
aligned_c3_tone_index = round(10 / aligned_df) + 1;
aligned_m2_tone_index = round(3 / aligned_df) + 1;
stale_montage_tone_index = round(20 / aligned_df) + 1;
verifyGreaterThan(testCase, ...
    aligned_median_spectrum(aligned_c3_tone_index), ...
    aligned_median_spectrum(stale_montage_tone_index) + 10)
verifyGreaterThan(testCase, ...
    aligned_median_spectrum(aligned_m2_tone_index), ...
    aligned_median_spectrum(stale_montage_tone_index) + 5)

ylim(native_axes, [1, 20])
drawnow
verifyEqual(testCase, aligned_axes.YLim, [1, 20], 'AbsTol', 1e-12)
end

function testMissingNativeChannelFails(testCase)
[EEG, header_final, signalHeader_final, signalCell_final] = ...
    make_fixture;
EEG.chanlocs(2).labels = 'Noise';

verifyError(testCase, @() sanity_check_spectrogram( ...
    EEG, header_final, signalHeader_final, signalCell_final), ...
    'sanity_check_spectrogram:MissingNativeChannel')
end

function testMissingGroundedAlignedChannelFails(testCase)
[EEG, header_final, signalHeader_final, signalCell_final] = ...
    make_fixture;
missing_index = strcmp( ...
    {signalHeader_final.signal_labels}, 'M2');
signalHeader_final(missing_index) = [];
signalCell_final(missing_index) = [];

verifyError(testCase, @() sanity_check_spectrogram( ...
    EEG, header_final, signalHeader_final, signalCell_final), ...
    'sanity_check_spectrogram:MissingAlignedChannel')
end

function testGroundedChannelSampleCountMismatchFails(testCase)
[EEG, header_final, signalHeader_final, signalCell_final] = ...
    make_fixture;
m2_index = strcmp({signalHeader_final.signal_labels}, 'M2');
signalCell_final{m2_index} = signalCell_final{m2_index}(1:end-1);

verifyError(testCase, @() sanity_check_spectrogram( ...
    EEG, header_final, signalHeader_final, signalCell_final), ...
    'sanity_check_spectrogram:SampleCountMismatch')
end

function [EEG, header_final, signalHeader_final, signalCell_final] = ...
    make_fixture

native_Fs = 500;
native_time = (0:1999) / native_Fs;
EEG.srate = native_Fs;
EEG.data = single([ ...
    12 + 3 * sin(2 * pi * 10 * native_time); ...
    -7 + sin(2 * pi * 3 * native_time)]);
EEG.chanlocs(1).labels = 'LA2';
EEG.chanlocs(2).labels = 'RD6';

aligned_Fs = 256;
aligned_time = (0:1023) / aligned_Fs;
header_final.data_record_duration = 1;
signal_labels = {'C3:M2', 'M2', 'C3'};
for channel_i = numel(signal_labels):-1:1
    signalHeader_final(channel_i).signal_labels = ...
        signal_labels{channel_i};
    signalHeader_final(channel_i).samples_in_record = aligned_Fs;
end

aligned_c3_m2 = ...
    2 * sin(2 * pi * 10 * aligned_time) + ...
    0.5 * sin(2 * pi * 3 * aligned_time);
clinical_m2 = ...
    100 + 0.75 * sin(2 * pi * 17 * aligned_time);
prepared_c3 = aligned_c3_m2 + clinical_m2;
stale_c3_m2 = 10 * sin(2 * pi * 20 * aligned_time);
signalCell_final = { ...
    stale_c3_m2, clinical_m2, prepared_c3.'};

end
