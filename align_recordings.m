function align_recordings(subject_code, trig_channel)
%% Sleep and EEG Recording Alignment with Stochastic (all night) Triggers
% Assumes that you have triggers throughout the night and 
% Last edit by Alex He 07/15/2026

%%%%%%%%%%%%%%%% Change these parameters

subject_code='sas_023';
trig_channel='TcPPG';

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%
if nargin < 2
    trig_channel = 'TcPPG';
end

%% Path configuration
addpath('~/Dropbox/Active_projects/EEG/code/sleepeeg_code')
addpath('~/Dropbox/Active_projects/EEG/code/ant_interface_code')

fpath = pwd;
fn_eeg = fullfile(fpath, subject_code, 'set', [subject_code '_sleep_ds500_Z3.set']);
fn_edf = fullfile(fpath, subject_code, 'clinical', 'HODRICK_ROBERT_(1).edf');

%% Load all data
% Load the trigger channel from EDF file
[header, signalHeader, signalCell] = SleepEEG_loadedf(fn_edf, {trig_channel});
trigger_Fs = signalHeader.samples_in_record ./ header.data_record_duration;
disp('EDF trigger channel Loaded........................................')

% Load the HD-EEG data so we can get the trigger events
[filepath, filename_no_ext, ext] = fileparts(fn_eeg);
filename = [filename_no_ext ext];
EEG = ANT_interface_loadset(filename, filepath);

% figure out scalp channel sampling rate in HD-EEG file
eeg_Fs = EEG.srate;

% assert the HD-EEG sampling rate
assert(eeg_Fs == 500, 'EEG sampling rate is different from 500Hz.')
disp('HD-EEG data Loaded........................................')

% Load all channels from EDF file
[header_all, signalHeader_all, signalCell_all] = SleepEEG_loadedf(fn_edf);

% figure out scalp channel sampling rate in the EDF file
c3_index = strcmp({signalHeader_all.signal_labels}, 'C3');
edf_Fs = signalHeader_all(c3_index).samples_in_record / header_all.data_record_duration;

% assert the EDF sampling rate
assert(edf_Fs == 256, 'EDF sampling rate is different from 256Hz.')
disp('Clinical EDF data Loaded......................................')

%% Extract triggers from the two files and match by trigger intervals
% Create two structs to hold useful variables
edf_input.DC_trace = signalCell{1};
edf_input.trigger_Fs = trigger_Fs;
edf_input.Fs = edf_Fs;

eeg_input.EEG = EEG;
eeg_input.Fs = eeg_Fs;

% First extract triggers from the HD-EEG events and EDF trigger channel 
[eeg_input, edf_input] = extract_triggers(eeg_input, edf_input, true);

% Now match trigger intervals between the two systems
[trigger_match_result, eeg_input, edf_input] = match_triggers(eeg_input, edf_input, true);

% Extract continuous matched-up segments based on matched-up trigger intervals
matched_segments = extract_segments(trigger_match_result, eeg_input, edf_input, true);
disp('Triggers matched up.............................')

%% Truncate relevant HD-EEG channels to within segment sample bounds
edf_eeg_channel_names = {'Fp1', 'Fp2', 'F3', 'F4', 'C3', 'C4', 'O1', 'O2', 'M1', 'M2'};
eeg_input.edf_eeg_channel_names = edf_eeg_channel_names;
eeg_segment_data = truncate_eeg_segments(matched_segments, eeg_input);
disp('HD-EEG channels truncated..........................')

%% Resample HD-EEG signal into EDF sampling rate
% Treat the EDF clock as the reference and estimate the effective HD-EEG
% sampling rate separately for each continuous matched segment.
edf_input.edf_eeg_channel_names = edf_eeg_channel_names;
resampled_eeg_segment_data = resample_eeg_segments(eeg_segment_data, matched_segments, edf_input, true); %#ok<NASGU>
disp('HD-EEG channels resampled..........................')

%% Construct header and signal header -- PICK UP WITH ANGELA HERE
% header 
header_final=header_all;
header_final.num_signals=header_all.num_signals+8; 
Fs=eeg_Fs;

% signal header 
clear signalHeader_final 
%Have EEG channels at the beginning, so that we don't have to move EDF Annotations
channel_labels={'F3','F4','C3','C4','O1','O2','M1E','M2E'};
for ii=1:8
    signalHeader_final(ii)=signalHeader_all(1); %#ok<*AGROW> % use clinical lead as template 
    signalHeader_final(ii).signal_labels=channel_labels{ii};
    signalHeader_final(ii).samples_in_record=Fs/2; 
    
    %Hardcoded from test of ANT system
    signalHeader_final(ii).physical_min=-83886;
    signalHeader_final(ii).physical_max=83886;
    signalHeader_final(ii).digital_min=-32768;
    signalHeader_final(ii).digital_max=32767;
end

% copy the signal header info for clinical leads 
for ii=1:size(resamp_trace,1)
    signalHeader_final(ii+8)=signalHeader_all(ii);
    signalHeader_final(ii+8).samples_in_record=Fs/2;
end

% moved here from above, delete later
desired_channels={'M1','M2','ECG-LA','ECG-RA','ECG-LL','ECG-V1','ECG-V2','E1','E2','CHIN1','CHIN2','CHIN3','LLEG+','LLEG-','RLEG+','RLEG-','Snore','PTAF','CFlow','Abdomen','Chest','XSum','SpO2','AirFlow','Airflow2','PR','IC1','IC2','Leak','Pleth','EDF Annotations'};
num_dc=length(desired_channels);
%%%%%%%%%

% copy the signal header info for annotation channel
anno_num = 8 + size(resamp_trace,1) + 1;
signalHeader_final(anno_num)=signalHeader_all(num_dc);

%% Add zeros so that EEG and annotations are at the right location
EEG_length_new = size(EEG_trunc,2);
% beg_pad is for how many samples should be there before the start sequence
beg_pad = zeros(1, ceil(sleep_ss(1,1)/signalHeader.samples_in_record*(Fs/2)));
% end_pad is the remaining samples to make up the full number of epochs as
% dictated by the Annotation channel (header_final.num_data_records)
end_pad = zeros(1, header_final.num_data_records*(Fs/2) - EEG_length_new - length(beg_pad));
% sanity check
assert(length(signalCell_all{num_dc})/signalHeader_final(anno_num).samples_in_record == ...
    (length(beg_pad)+EEG_length_new+length(end_pad))/signalHeader_final(1).samples_in_record && ...
    length(signalCell_all{num_dc})/signalHeader_final(anno_num).samples_in_record ==...
    header_final.num_data_records, 'Total number of epochs is off. Annotation channel might not write properly!')

disp('Header and Signal Header constructed..........................')

%% Make time traces of HD-EEG data 
sleep_chans=zeros(8,EEG_length_new);

% construct a cell array of HD-EEG labels for lead extraction
for ii=1:length(EEG.chanlocs)
    EEG_label{ii}=EEG.chanlocs(ii).labels;
end

F_lead = extract_lead(EEG_trunc, EEG_label, 'LL2'); %F3
sleep_chans(1,:)=F_lead;
F_lead = extract_lead(EEG_trunc, EEG_label, 'RR2'); %F4
sleep_chans(2,:)=F_lead;
C_lead = extract_lead(EEG_trunc, EEG_label, 'LA2'); %C3
sleep_chans(3,:)=C_lead;
C_lead = extract_lead(EEG_trunc, EEG_label, 'RA2'); %C4
sleep_chans(4,:)=C_lead;
O_lead = extract_lead(EEG_trunc, EEG_label, 'LL11'); %O1
sleep_chans(5,:)=O_lead;
O_lead = extract_lead(EEG_trunc, EEG_label, 'RR11'); %O2
sleep_chans(6,:)=O_lead;

M1_lead=extract_lead(EEG_trunc, EEG_label, 'LD6'); %add into edf
sleep_chans(7,:)=M1_lead;
M2_lead=extract_lead(EEG_trunc, EEG_label, 'RD6');
sleep_chans(8,:)=M2_lead; % alex - small correction of typo of variable name

%% Construct signalCell
% add EEG channels to signalCell
assert(size(sleep_chans,2) == EEG_length_new, 'Something is wrong about the signal length!')
for ii=1:8
    signalCell_final{1,ii}=[beg_pad sleep_chans(ii,:) end_pad]; 
end

% add Sleep channels to signalCell
assert(size(resamp_trace,2) == EEG_length_new, 'Something is wrong about the signal length!')
for ii=1:size(resamp_trace,1)
    signalCell_final{1,ii+8}=[beg_pad resamp_trace(ii,:) end_pad];
end

% add annotation channel to signalCell
signalCell_final{1,anno_num} = signalCell_all{1,num_dc};

disp('signalCell constructed .....................................')

%% Final checks before saving - this section takes a long time
% sanity check of signal timetraces and saturating filter - Alex added on 03/07/2020
for ii=1:8
    current_signal = signalCell_final{1,ii};
    current_signal_copy = current_signal;
    t = linspace(0, length(current_signal)/Fs,  length(current_signal));
    
    % saturating filters
    below_min = current_signal < signalHeader_final(ii).physical_min;
    if sum(below_min) > 0
        warning (['physical min exceeded for some values in channel ', channel_labels{ii} ,', saturated to be at physical min!'])
        current_signal(below_min) = signalHeader_final(ii).physical_min;
    end
    above_max = current_signal > signalHeader_final(ii).physical_max;
    if sum(above_max) > 0
        warning (['physical max exceeded for some values in channel ', channel_labels{ii} ,', saturated to be at physical max!'])
        current_signal(above_max) = signalHeader_final(ii).physical_max;
    end
    
    % generate a plot for debugging purpose on the un-saturated signal
    figure
    hold on
    plot(t, current_signal_copy)
    plot(xlim, [signalHeader_final(ii).physical_max, signalHeader_final(ii).physical_max], 'g', 'LineWidth', 2)
    plot(xlim, [signalHeader_final(ii).physical_min, signalHeader_final(ii).physical_min], 'g', 'LineWidth', 2)
    title(channel_labels{ii}, 'FontSize', 20)
    exthresh = below_min |  above_max;
    scatter(t(exthresh), current_signal_copy(exthresh), 'r')
    
    picname = ['/autofs/cifs/adsleepeeg/archive/subject_data/' subject_code '/clinical/' subject_code '_night' num2str(night),...
        '_set2edf_trace_', channel_labels{ii}, '.png'];
    saveas(gca, picname);
    
    signalCell_final{1,ii} = current_signal;
    assert(min(signalCell_final{1,ii}) >= signalHeader_final(ii).physical_min, 'Saturating filter failed!')
    assert(max(signalCell_final{1,ii}) <= signalHeader_final(ii).physical_max, 'Saturating filter failed!')
end

%prepare structure for reverse alignment - Alex added on 02/20/2020
% added structure store for reverse alignment back to EEG timeframe
rvsalign_store = struct;
rvsalign_store.truncate_startidx = eeg_ss(1,1); % match_global(1,1); Alex updated on 08/01/2022
rvsalign_store.truncate_endidx = eeg_ss(end,end); % match_global(end,1);
rvsalign_store.original_length = size(EEG.data,2);
rvsalign_store.begin_pad = length(beg_pad);
rvsalign_store.end_pad = length(end_pad);
structfn = ['/autofs/cifs/adsleepeeg/archive/subject_data/' subject_code '/clinical/' subject_code '_night' num2str(night) '_rvsalign.mat'];
save(structfn, 'rvsalign_store')

%update the annotation channel with custom-made annotation channel
new_anno = SleepEEG_buildannot(fn_edf);
signalCell_final{1,anno_num} = new_anno;

%save a matching of EOG and clinical E1 channels to verify the quality of
%alignment - added by Alex on 06/18/2021
H = figure;
hold on
plot(signalCell_final{16})
HD_EOG = EEG_trunc(129,:);
plot([beg_pad HD_EOG - mean(HD_EOG) end_pad])
legend('Clinical E1','HD EOG')
savefig(H, ['/autofs/cifs/adsleepeeg/archive/subject_data/' subject_code '/clinical/' subject_code '_night' num2str(night), '_EOG_compare.fig'])

disp('Final checks passed .....................................')

%% Save aligned EDF file 
edfFN=['/autofs/cifs/adsleepeeg/archive/subject_data/' subject_code '/clinical/' subject_code '_night' num2str(night) '_aligned.edf'];
[statusHeader statusSignalHeader statusSignalCell] = blockEdfWrite(edfFN, header_final,  signalHeader_final, signalCell_final); %#ok<*NCOMMA,*ASGLU>
disp('EDF Saved.....................................')
disp('Script done.')
close all

end
