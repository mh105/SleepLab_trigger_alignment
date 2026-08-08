function tests = test_faulty_clinical_detection
tests = functiontests(localfunctions);
end

function setupOnce(~)
project_path = fileparts(fileparts(mfilename('fullpath')));
addpath(project_path)
addpath(fullfile(project_path, 'helper_functions'))
end

function testUsesMatchedSamplesAndReportsFaultyStatus(testCase)
[signalHeader_all, signalCell_all] = make_fixture(10);
signal_labels = {signalHeader_all.signal_labels};
matched_sample_mask = false(1, 10);
matched_sample_mask(1:5) = true; %#ok<NASGU>
signalCell_all{strcmp(signal_labels, 'M1')} = ...
    [1000; zeros(4, 1); 2000; 2000; 2000; 2000; 2000];
signalCell_all{strcmp(signal_labels, 'M2')} = ...
    [zeros(5, 1); 2000; 2000; 2000; 2000; 2000]; %#ok<NASGU>

[report_output, clinical_system_faulty] = evalc( ...
    'faulty_clinical_detection(signalHeader_all, signalCell_all, matched_sample_mask)');

verifyTrue(testCase, clinical_system_faulty)
verifyTrue(testCase, contains(report_output, 'Matched samples: 5'))
verifyTrue(testCase, contains(report_output, 'Total samples: 10'))
verifyTrue(testCase, contains(report_output, ...
    'Matched coverage: 50.000000%'))
verifyTrue(testCase, contains(report_output, ...
    'M1 abs(signal) >= 1000 uV: 20.000000%'))
verifyTrue(testCase, contains(report_output, ...
    'M2 abs(signal) >= 1000 uV: 0.000000%'))
verifyTrue(testCase, contains(report_output, ...
    'Mean M1/M2 proportion: 10.000000%'))
verifyTrue(testCase, contains(report_output, 'Status: FAULTY'))
verifyFalse(testCase, contains(report_output, '**'))
end

function testExactlyTwoPercentIsNormalAndThresholdIsInclusive(testCase)
n_samples = 100;
[signalHeader_all, signalCell_all] = make_fixture(n_samples);
signal_labels = {signalHeader_all.signal_labels};
matched_sample_mask = true(n_samples, 1); %#ok<NASGU>
signalCell_all{strcmp(signal_labels, 'M1')} = ...
    [1000, -1000, zeros(1, n_samples - 2)];
signalCell_all{strcmp(signal_labels, 'M2')} = ...
    [1000; -1000; zeros(n_samples - 2, 1)]; %#ok<NASGU>

[report_output, clinical_system_faulty] = evalc( ...
    'faulty_clinical_detection(signalHeader_all, signalCell_all, matched_sample_mask)');

verifyFalse(testCase, clinical_system_faulty)
verifyTrue(testCase, contains(report_output, ...
    'Mean M1/M2 proportion: 2.000000%'))
verifyTrue(testCase, contains(report_output, 'Status: NORMAL'))
end

function testUnroundedMeanAboveTwoPercentIsFaulty(testCase)
n_samples = 10000;
[signalHeader_all, signalCell_all] = make_fixture(n_samples);
signal_labels = {signalHeader_all.signal_labels};
matched_sample_mask = true(1, n_samples);
m1_data = zeros(1, n_samples);
m2_data = zeros(n_samples, 1);
m1_data(1:201) = 1000;
m2_data(1:200) = -1000;
signalCell_all{strcmp(signal_labels, 'M1')} = m1_data;
signalCell_all{strcmp(signal_labels, 'M2')} = m2_data;

clinical_system_faulty = faulty_clinical_detection( ...
    signalHeader_all, signalCell_all, matched_sample_mask);

verifyTrue(testCase, clinical_system_faulty)
end

function testNonfiniteUnmatchedSamplesAreIgnored(testCase)
[signalHeader_all, signalCell_all] = make_fixture(5);
signal_labels = {signalHeader_all.signal_labels};
matched_sample_mask = [true, true, true, false, false];
signalCell_all{strcmp(signal_labels, 'M1')} = [0, 0, 0, NaN, Inf];
signalCell_all{strcmp(signal_labels, 'M2')} = [0; 0; 0; NaN; -Inf];

clinical_system_faulty = faulty_clinical_detection( ...
    signalHeader_all, signalCell_all, matched_sample_mask);

verifyFalse(testCase, clinical_system_faulty)
end

function testMissingAndDuplicateMastoidLabelsFail(testCase)
[signalHeader_all, signalCell_all] = make_fixture(5);
matched_sample_mask = true(1, 5);
missing_header = signalHeader_all;
missing_header(strcmp({missing_header.signal_labels}, 'M2')).signal_labels = ...
    'Noise 2';
verifyError(testCase, @() faulty_clinical_detection( ...
    missing_header, signalCell_all, matched_sample_mask), ...
    'faulty_clinical_detection:MissingEdfChannel')

duplicate_header = signalHeader_all;
duplicate_header(strcmp( ...
    {duplicate_header.signal_labels}, 'Noise')).signal_labels = 'M1';
verifyError(testCase, @() faulty_clinical_detection( ...
    duplicate_header, signalCell_all, matched_sample_mask), ...
    'faulty_clinical_detection:DuplicateEdfChannel')
end

function testInvalidMasksFail(testCase)
[signalHeader_all, signalCell_all] = make_fixture(5);

verifyError(testCase, @() faulty_clinical_detection( ...
    signalHeader_all, signalCell_all, ones(1, 5)), ...
    'faulty_clinical_detection:InvalidMatchedSampleMask')
verifyError(testCase, @() faulty_clinical_detection( ...
    signalHeader_all, signalCell_all, false(0, 1)), ...
    'faulty_clinical_detection:InvalidMatchedSampleMask')
verifyError(testCase, @() faulty_clinical_detection( ...
    signalHeader_all, signalCell_all, false(1, 5)), ...
    'faulty_clinical_detection:NoMatchedSamples')
verifyError(testCase, @() faulty_clinical_detection( ...
    signalHeader_all, signalCell_all, true(1, 4)), ...
    'faulty_clinical_detection:MaskLengthMismatch')
end

function testInvalidMetadataFails(testCase)
[signalHeader_all, signalCell_all] = make_fixture(5);
matched_sample_mask = true(1, 5);
m1_index = strcmp({signalHeader_all.signal_labels}, 'M1');
m2_index = strcmp({signalHeader_all.signal_labels}, 'M2');

invalid_rate_header = signalHeader_all;
invalid_rate_header(m1_index).samples_in_record = 128;
verifyError(testCase, @() faulty_clinical_detection( ...
    invalid_rate_header, signalCell_all, matched_sample_mask), ...
    'faulty_clinical_detection:InvalidSamplingRate')

invalid_unit_header = signalHeader_all;
invalid_unit_header(m2_index).physical_dimension = 'mV';
verifyError(testCase, @() faulty_clinical_detection( ...
    invalid_unit_header, signalCell_all, matched_sample_mask), ...
    'faulty_clinical_detection:InvalidPhysicalDimension')
end

function testInvalidSignalsFail(testCase)
[signalHeader_all, signalCell_all] = make_fixture(5);
signal_labels = {signalHeader_all.signal_labels};
matched_sample_mask = true(1, 5);

invalid_shape_cells = signalCell_all;
invalid_shape_cells{strcmp(signal_labels, 'M1')} = zeros(2, 3);
verifyError(testCase, @() faulty_clinical_detection( ...
    signalHeader_all, invalid_shape_cells, matched_sample_mask), ...
    'faulty_clinical_detection:InvalidSignalData')

nonfinite_cells = signalCell_all;
nonfinite_cells{strcmp(signal_labels, 'M2')}(3) = NaN;
verifyError(testCase, @() faulty_clinical_detection( ...
    signalHeader_all, nonfinite_cells, matched_sample_mask), ...
    'faulty_clinical_detection:NonfiniteMatchedSamples')
end

function testSignalCountMismatchFails(testCase)
[signalHeader_all, signalCell_all] = make_fixture(5);

verifyError(testCase, @() faulty_clinical_detection( ...
    signalHeader_all, signalCell_all(1:end - 1), true(1, 5)), ...
    'faulty_clinical_detection:SignalCountMismatch')
end

function [signalHeader_all, signalCell_all] = make_fixture(n_samples)
signal_labels = {'Noise', 'M2', 'E1', 'M1'};
for channel_i = numel(signal_labels):-1:1
    signalHeader_all(channel_i).signal_labels = signal_labels{channel_i};
    signalHeader_all(channel_i).samples_in_record = 256;
    signalHeader_all(channel_i).physical_dimension = 'uV';
end

signalCell_all = { ...
    zeros(2, 1), ...
    zeros(n_samples, 1), ...
    zeros(1, n_samples), ...
    zeros(1, n_samples)};
end
