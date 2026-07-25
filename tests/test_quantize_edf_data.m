function tests = test_quantize_edf_data
tests = functiontests(localfunctions);
end

function setupOnce(~)
project_path = fileparts(fileparts(mfilename('fullpath')));
addpath(project_path)
addpath(fullfile(project_path, 'helper_functions'))
end

function testUpdatesSharedHeadersAndQuantizesOnlyClinicalChannels(testCase)
[signalHeader_all, signalCell_all] = make_fixture;

[signalHeader_final, signalCell_final] = quantize_edf_data( ...
    signalHeader_all, signalCell_all);

shared_grid_channel_names = { ...
    'Fp1', 'Fp2', 'F3', 'F4', 'C3', 'C4', 'O1', 'O2', ...
    'E1', 'E2', 'M1', 'M2'};
quantized_channel_names = {'E1', 'E2', 'M1', 'M2'};
signal_labels = {signalHeader_all.signal_labels};

for channel_i = 1:numel(signal_labels)
    channel_name = signal_labels{channel_i};
    if ismember(channel_name, shared_grid_channel_names)
        verifyEqual(testCase, ...
            signalHeader_final(channel_i).physical_min, -1800)
        verifyEqual(testCase, ...
            signalHeader_final(channel_i).physical_max, 1800)
        verifyEqual(testCase, ...
            signalHeader_final(channel_i).digital_min, ...
            signalHeader_all(channel_i).digital_min)
        verifyEqual(testCase, ...
            signalHeader_final(channel_i).digital_max, ...
            signalHeader_all(channel_i).digital_max)
    else
        verifyEqual(testCase, ...
            signalHeader_final(channel_i), signalHeader_all(channel_i))
    end

    if ismember(channel_name, quantized_channel_names)
        expected = quantize_to_header_grid( ...
            signalCell_all{channel_i}, signalHeader_final(channel_i));
        verifyEqual(testCase, signalCell_final{channel_i}, expected, ...
            'AbsTol', 1e-12)
        verifySize(testCase, signalCell_final{channel_i}, ...
            size(signalCell_all{channel_i}))
        verifyClass(testCase, signalCell_final{channel_i}, 'double')
    else
        verifyEqual(testCase, ...
            signalCell_final{channel_i}, signalCell_all{channel_i})
    end
end

verifySize(testCase, signalHeader_final, size(signalHeader_all))
verifySize(testCase, signalCell_final, size(signalCell_all))
end

function testClinicalValuesOutsideNewRangeAreClipped(testCase)
[signalHeader_all, signalCell_all] = make_fixture;
signal_labels = {signalHeader_all.signal_labels};
e1_index = strcmp(signal_labels, 'E1');
signalCell_all{e1_index} = [-1801, -1800, 1800, 1801];

[~, signalCell_final] = quantize_edf_data( ...
    signalHeader_all, signalCell_all);

verifyEqual(testCase, signalCell_final{e1_index}, ...
    [-1800, -1800, 1800, 1800])
end

function testQuantizedMastoidCancelsOnSharedGrid(testCase)
[signalHeader_all, signalCell_all] = make_fixture;
signal_labels = {signalHeader_all.signal_labels};
n_samples = numel(signalCell_all{strcmp(signal_labels, 'M2')});
physical_min = -1800;
physical_max = 1800;
digital_min = -32768;
digital_max = 32767;
quantization_step_uV = ...
    (physical_max - physical_min) / (digital_max - digital_min);
mastoid_digital_code = 1000;
raw_mastoid = physical_min + ...
    (mastoid_digital_code - digital_min + 0.49) * ...
    quantization_step_uV;
m2_index = strcmp(signal_labels, 'M2');
signalCell_all{m2_index} = repmat(raw_mastoid, n_samples, 1);

edf_eeg_channel_names = { ...
    'Fp1', 'Fp2', 'F3', 'F4', 'C3', 'C4', 'O1', 'O2'};
aligned_eeg_channel_names = [ ...
    edf_eeg_channel_names, {'M1', 'M2', 'VEOGL'}];
final_eeg_data = zeros( ...
    numel(aligned_eeg_channel_names), n_samples);
desired_c3_m2 = repmat( ...
    1.49 * quantization_step_uV, 1, n_samples);
final_eeg_data(strcmp(aligned_eeg_channel_names, 'C3'), :) = ...
    desired_c3_m2;

[signalHeader_final, signalCell_quantized] = quantize_edf_data( ...
    signalHeader_all, signalCell_all);
signalCell_substituted = substitute_eeg_data( ...
    final_eeg_data, aligned_eeg_channel_names, ...
    edf_eeg_channel_names, signalHeader_final, ...
    signalCell_quantized, false);

c3_index = strcmp(signal_labels, 'C3');
written_c3_code = encode_to_header_grid( ...
    signalCell_substituted{c3_index}, signalHeader_final(c3_index));
written_m2_code = encode_to_header_grid( ...
    signalCell_substituted{m2_index}, signalHeader_final(m2_index));
written_c3 = quantize_to_header_grid( ...
    signalCell_substituted{c3_index}, signalHeader_final(c3_index));
written_m2 = quantize_to_header_grid( ...
    signalCell_substituted{m2_index}, signalHeader_final(m2_index));
displayed_c3_m2 = ...
    reshape(written_c3, 1, []) - reshape(written_m2, 1, []);

verifyEqual(testCase, written_m2_code, ...
    repmat(mastoid_digital_code, size(written_m2_code)))
verifyEqual(testCase, written_c3_code, ...
    repmat(mastoid_digital_code + 1, size(written_c3_code)))
verifyEqual(testCase, written_m2, signalCell_quantized{m2_index}, ...
    'AbsTol', 1e-12)
verifyEqual(testCase, displayed_c3_m2, ...
    repmat(quantization_step_uV, 1, n_samples), ...
    'AbsTol', 1e-10)
end

function testMissingSharedGridChannelFails(testCase)
[signalHeader_all, signalCell_all] = make_fixture;
missing_index = strcmp({signalHeader_all.signal_labels}, 'E1');
signalHeader_all(missing_index) = [];
signalCell_all(missing_index) = [];

verifyError(testCase, @() quantize_edf_data( ...
    signalHeader_all, signalCell_all), ...
    'quantize_edf_data:MissingEdfChannel')
end

function testDuplicateSharedGridChannelFails(testCase)
[signalHeader_all, signalCell_all] = make_fixture;
duplicate_index = strcmp({signalHeader_all.signal_labels}, 'M2');
signalHeader_all(end + 1) = signalHeader_all(duplicate_index);
signalCell_all{end + 1} = signalCell_all{duplicate_index};

verifyError(testCase, @() quantize_edf_data( ...
    signalHeader_all, signalCell_all), ...
    'quantize_edf_data:DuplicateEdfChannel')
end

function testSignalCountMismatchFails(testCase)
[signalHeader_all, signalCell_all] = make_fixture;

verifyError(testCase, @() quantize_edf_data( ...
    signalHeader_all, signalCell_all(1:end-1)), ...
    'quantize_edf_data:SignalCountMismatch')
end

function testInconsistentDigitalLimitsFail(testCase)
[signalHeader_all, signalCell_all] = make_fixture;
e2_index = strcmp({signalHeader_all.signal_labels}, 'E2');
signalHeader_all(e2_index).digital_max = 2047;

verifyError(testCase, @() quantize_edf_data( ...
    signalHeader_all, signalCell_all), ...
    'quantize_edf_data:InconsistentDigitalLimits')
end

function [signalHeader_all, signalCell_all] = make_fixture
signal_labels = { ...
    'PAP Pres', 'M2', 'Fp1', 'E2:M1', 'F4', 'E1', 'C3', ...
    'Fp2', 'M1', 'O2', 'F3', 'E2', 'O1', 'C4', ...
    'Fp1:M2', 'E1:M2', 'EDF Annotations'};
n_samples = 6;

for channel_i = numel(signal_labels):-1:1
    signalHeader_all(channel_i).signal_labels = signal_labels{channel_i};
    signalHeader_all(channel_i).physical_dimension = 'uV';
    signalHeader_all(channel_i).physical_min = -1465;
    signalHeader_all(channel_i).physical_max = 1465;
    signalHeader_all(channel_i).digital_min = -32768;
    signalHeader_all(channel_i).digital_max = 32767;
end

signalCell_all = cell(1, numel(signal_labels));
for channel_i = 1:numel(signal_labels)
    channel_data = channel_i * 10 + (1:n_samples);
    if mod(channel_i, 2) == 0
        channel_data = channel_data.';
    end
    signalCell_all{channel_i} = channel_data;
end

signalCell_all{strcmp(signal_labels, 'E1')} = ...
    [-2000, -1800, -0.01, 0, 1799.99, 2000];
signalCell_all{strcmp(signal_labels, 'E2')} = ...
    single([-1000; -10; -0.02; 0.03; 10; 1000]);
signalCell_all{strcmp(signal_labels, 'M1')} = ...
    int16([-900, -100, -1, 1, 100, 900]);
signalCell_all{strcmp(signal_labels, 'M2')} = ...
    [-700.02; -100.01; -0.04; 0.04; 100.01; 700.02];
signalCell_all{strcmp(signal_labels, 'PAP Pres')} = ...
    single(1:n_samples);
signalCell_all{strcmp(signal_labels, 'EDF Annotations')} = ...
    uint8(1:n_samples);
end

function quantized_data = quantize_to_header_grid(signal_data, signal_header)
digital_data = encode_to_header_grid(signal_data, signal_header);
digital_min = double(signal_header.digital_min);
digital_max = double(signal_header.digital_max);
physical_min = double(signal_header.physical_min);
physical_max = double(signal_header.physical_max);
quantized_data = ...
    (digital_data - digital_min) / ...
    (digital_max - digital_min);
quantized_data = ...
    quantized_data * (physical_max - physical_min) + physical_min;
quantized_data = reshape(quantized_data, size(signal_data));
end

function digital_data = encode_to_header_grid(signal_data, signal_header)
digital_min = double(signal_header.digital_min);
digital_max = double(signal_header.digital_max);
physical_min = double(signal_header.physical_min);
physical_max = double(signal_header.physical_max);

digital_data = ...
    (double(signal_data) - physical_min) / ...
    (physical_max - physical_min);
digital_data = double(int16( ...
    digital_data * (digital_max - digital_min) + digital_min));
digital_data = reshape(digital_data, size(signal_data));
end
