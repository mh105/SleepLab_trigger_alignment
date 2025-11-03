function align_recordings(subject_code,night,trig_channel)
%% Sleep and EEG Recording Alignment with Stochastic (all night) Triggers
% Assumes that you have triggers throughout the night and 
% Last edit by Amanda M Beck 3/25/21

%%%%%%%%%%%%%%%% Change these parameters

% subject_code='CBAN_F_56';
% night='1';
% trig_channel='DC7'

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Prepare Data
sleep_Fs=512;
eeg_Fs=500;
end_seq=logical(1);

addpath(genpath('/autofs/cifs/adsleepeeg/users/alexhe'))
addpath('/autofs/cluster/purdonlab/code/matlab/eeg_analysis')
addpath('/autofs/cifs/adsleepeeg/code/sleepeeg_code')
addpath('/autofs/cifs/adsleepeeg/code/sleepeeg_code/EDF_Deidentification_updated/')

fpath = ['/autofs/cifs/adsleepeeg/archive/subject_data/' subject_code '/'];
fn_eeg = [fpath 'set/' subject_code '_night' night '_Sleep_ds500_Z3.set'];
fn_sleep = [fpath 'clinical/' subject_code '_night' night '_Sleep_clinical_deidentified.edf'];

[header, signalHeader, signalCell]=SleepEEG_loadedf(fn_sleep,{trig_channel}); %Need true channel
EEG_new=SleepEEG_loadset(subject_code,['night' night '_Sleep'],true);

sleep_input.DC_trace=signalCell{1,1};
sleep_input.Fs_ds=sleep_Fs; %we will downsample later
eeg_input.EEG=EEG_new;
eeg_input.Fs=eeg_Fs;

[sleep_output, eeg_output, sleep_input]=record_summary(sleep_input,eeg_input, signalHeader, header);

sleep_output.trig_diff=trig_distances(sleep_output.trig_index,sleep_input.Fs);
eeg_output.trig_diff=trig_distances(eeg_output.trig_index,eeg_input.Fs);

%% Load all Sleep data
desired_channels={'M1','M2','ECG-LA','ECG-RA','ECG-LL','ECG-V1','ECG-V2','E1','E2','CHIN1','CHIN2','CHIN3','LLEG+','LLEG-','RLEG+','RLEG-','Snore','PTAF','CFlow','Abdomen','Chest','XSum','SpO2','AirFlow','Airflow2','PR','IC1','IC2','Leak','Pleth','EDF Annotations'};
num_dc=length(desired_channels);
[header_all, signalHeader_all, signalCell_all]=SleepEEG_loadedf(fn_sleep,desired_channels);
whole_trace=zeros((length(signalCell_all)-1),length(signalCell_all{1,1}));
for ii=1:(length(signalCell_all)-1)
    whole_trace(ii,:)=signalCell_all{1,ii};
end


%% If you have a start sequence, Truncate triggers
%startg for global
[sleep_startg, sleep_startdiff] = start_sequence(sleep_output.trig_diff, sleep_output.trig_index);
[eeg_startg, eeg_startdiff] = start_sequence(eeg_output.trig_diff,eeg_output.trig_index);

%choose which start sequence %prompt person
[rowss, colss]=size(sleep_startdiff);
[rowes, coles]=size(eeg_startdiff);
if (colss~=2) || (coles~=2)
   sleep_startdiff
   sleep_start=input('Which is the sleep start sequence?');
   sleep_end=input('Which is the sleep end sequence?');
else
    sleep_start=1;
    sleep_end=2;
end
    
if (colss~=2) || (coles~=2)
    eeg_startdiff   
    eeg_start=input('Which is the eeg start sequence?'); 
    eeg_end=input('Which is the eeg end sequence?'); 
else
    eeg_start=1;
    eeg_end=2;
end

sleep_output.trig_index_new=sleep_output.trig_index(sleep_startdiff(4,sleep_start):sleep_startdiff(1,sleep_end)); %does this need to be 3
eeg_output.trig_index_new=eeg_output.trig_index(eeg_startdiff(4,eeg_start):eeg_startdiff(1,eeg_end));


%% check match up interval lengths
sleep_output.trig_diff=trig_distances(sleep_output.trig_index_new,sleep_input.Fs);
eeg_output.trig_diff=trig_distances(eeg_output.trig_index_new,eeg_input.Fs);

sleep_tdiff=sleep_output.trig_diff;
eeg_tdiff=eeg_output.trig_diff;

compare_diff2=zeros(length(eeg_tdiff),4);
match_index=1;
int_bad=[];

compare_diff3=zeros(length(sleep_tdiff),4);
ii=1
while (ii <= length(sleep_tdiff))
    %disp(['round ' num2str(ii)])
    
    if (match_index<=length(eeg_tdiff)) & (abs(sleep_tdiff(ii)-eeg_tdiff(match_index))<0.1);%<0.0002); %use for most
        compare_diff3(ii,:)=[eeg_tdiff(match_index) sleep_tdiff(ii) match_index ii];
        match_index=match_index+1;
        %disp(['match index: ' num2str(match_index)]);
        ii=ii+1;
    elseif match_index < length(eeg_tdiff)
        compare_diff3(ii,:)= [ 0 sleep_tdiff(ii) 0 ii];
        ii=ii+1;
        delta=1;
        while (delta > 0.0002) %& (match_index < length(eeg_tdiff))
            delta_temp=abs(sleep_tdiff(ii)-eeg_tdiff(match_index));
            
            if delta_temp < 0.0002
                compare_diff3(ii,:)=[eeg_tdiff(match_index) sleep_tdiff(ii) match_index ii];
                match_index=match_index+1;
                ii=ii+1
                delta=delta_temp;
            else
                match_index=match_index+1;
            end
        end
    else
        ii=length(sleep_tdiff)+1;
    end    
end

if end_seq
    ind=find(compare_diff3(:,3)==match_index-1);
    compare_diff3((ind+1):end,:)=[];
end

compare_diff2=zeros(length(eeg_tdiff),4);
compare_diff2(:,1)=eeg_tdiff';
compare_diff2(:,3)=[1:length(eeg_tdiff)]';
min_length=min([length(sleep_tdiff) length(eeg_tdiff) length(compare_diff3)]);
for ii=1:min_length;
    if compare_diff3(ii,3)~= 0 
        eeg_ind=compare_diff3(ii,3);
        compare_diff2(eeg_ind,4)=compare_diff3(ii,4);
        compare_diff2(eeg_ind,2)=compare_diff3(ii,2);
    end
end
        

%% Matching Indexes
match_indexes=compare_diff2(:,3:4); 
for ii=[(length(eeg_tdiff)):-1:2]
    if (match_indexes(ii,2)==0) & (match_indexes(ii-1,2)~=0)
        match_indexes(ii,2)=match_indexes(ii-1,2)+1
    end
end

match_global=zeros(size(match_indexes));
[rowm colm]=size(match_indexes);
for ii=1:rowm
    if match_indexes(ii,2)~=0
        match_global(ii,:)=[eeg_output.trig_index_new(match_indexes(ii,1)) sleep_output.trig_index_new(match_indexes(ii,2))];
    else
        match_global(ii,:)=[eeg_output.trig_index_new(match_indexes(ii,1)) 0];
    end
end

[non_zeros]=find(match_global(:,2));
match_norm=match_global(:,2);
match_norm(non_zeros)=1;
match_norm=[0; match_norm; 0];
match_diff=diff(match_norm);
[start_index]=find(match_diff==1);
[end_index]=find(match_diff==-1);
sleep_ss=zeros(2,length(end_index));

sleep_ss(1,:)=match_global(start_index,2);
sleep_ss(2,:)=match_global(end_index-1,2);
eeg_ss(1,:)=match_global(start_index,1);
eeg_ss(2,:)=match_global(end_index-1,1);

%match_global is all matched indexes
%match_global is missing the first trigger.

%% Quick Check to check chunks
sleep_length=diff(sleep_ss)/(512*60);
eeg_length=diff(eeg_ss)/(500*60);
display('Do the recordings line up?')
for ii=1:length(sleep_length)
    display(['Chunk #:' num2str(ii) ' Sleep = ' num2str(sleep_length(ii)) ' min, EEG =' num2str(eeg_length(ii)) ' min'])
end
real_sleep_Fs=(diff(sleep_ss)+1)/(eeg_length*60);
display(['Real Sleep Sampling Frequency is ' num2str(real_sleep_Fs) ' Hz']);


%% Truncate
EEG=EEG_new;
EEG=rmfield(EEG,'event');

ind_new=0;
for ii=2:length(EEG_new.event)
    if find(match_global(:,1)==EEG_new.event(ii).latency)
        ind_new=ind_new+1;
        %disp('processing')
        EEG.event(ind_new).latency=EEG_new.event(ii).latency;
        EEG.event(ind_new).type=EEG_new.event(ii).type;
        EEG.event(ind_new).duration=EEG_new.event(ii).duration;
        EEG.event(ind_new).latency=EEG.event(ind_new).latency-EEG.event(1).latency;
    end  
end


if ~isa(EEG_new.data, 'single') % this step takes a while and may be avoided
    EEG_trunc=single(EEG_new.data); 
else
    EEG_trunc=EEG_new.data; 
end
EEG_trunc=EEG_trunc(:,match_global(1,1):match_global(end,1));
latency = match_global(:,1) - match_global(1,1) +1;


EEG.data=EEG_trunc;
EEG.event=latency;


%% Resample
[resamp_trace, resamp_time, sleep_trace, sleep_time] =interp_to_eeg(match_global, compare_diff2,whole_trace,EEG_new.times);

EEG.times=resamp_time;
EEG.times=[resamp_time resamp_time(end)+2]; % alex - why this step?
EEG.pnts=length(EEG.times);
verbose = logical(1);
EEG.xmin=EEG.times(1);
EEG.xmax=EEG.times(end);

%% Add zeros so that EEG and annotations are at the right location

channel_labels={'F3','F4','C3','C4','O1','O2','M1E','M2E'};
header_final=header_all;
header_final.num_signals=header_all.num_signals+8; 
Fs=eeg_Fs;

for ii=1:8
    %signalCell_final{1,ii}=sleep_chans(ii,1:EEG_length_new);
    signalHeader_final(ii)=signalHeader_all(1);
    signalHeader_final(ii).signal_labels=channel_labels{ii};
    signalHeader_final(ii).samples_in_record=Fs/2; %Fs should be true
    
    %Hardcoded from test of ANT system
    signalHeader_final(ii).physical_min=-83886;
    signalHeader_final(ii).physical_max=83886;
    signalHeader_final(ii).digital_min=-32768;
    signalHeader_final(ii).digital_max=32767;
end

for ii=1:size(resamp_trace,1)
    %signalCell_final{1,ii+8}=resamp_trace(ii,1:EEG_length_new);
    signalHeader_final(ii+8)=signalHeader_all(ii);
    signalHeader_final(ii+8).samples_in_record=Fs/2;
end

anno_num=length(signalHeader_final)+1;
signalHeader_final(anno_num)=signalHeader_all(num_dc);

% Alex added this part
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
    

%% Make time traces
sleep_chans=zeros(8,EEG_length_new); % I moved it here...

for ii=1:128
    EEG_label{ii}=EEG_new.chanlocs(ii).labels;
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
sleep_chans(8,:)= M2_lead; % alex - small correction of typo of variable name

%Have EEG channels at the beginning, so that we don't have to move EDF
%Annotations

header_final=header_all;
header_final.num_signals=header_all.num_signals+8; %6 EEG channels % -1 for EDF annotation

assert(size(sleep_chans,2) == EEG_length_new, 'Something is wrong about the signal length!')
for ii=1:8
    signalCell_final{1,ii}=[beg_pad sleep_chans(ii,:) end_pad];
end

assert(size(resamp_trace,2) == EEG_length_new, 'Something is wrong about the signal length!')
for ii=1:size(resamp_trace,1)
    signalCell_final{1,ii+8}=[beg_pad resamp_trace(ii,:) end_pad];
end

signalCell_final{1,anno_num}=signalCell_all{1,num_dc};
header_final.num_data_records= length(signalCell_final{1,anno_num})/signalHeader_final(anno_num).samples_in_record;

% sanity check of signal timetraces and saturating filter - Alex added on 03/07/2020
for ii=1:8 %through M
    
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
rvsalign_store.truncate_startidx = match_global(1,1);
rvsalign_store.truncate_endidx = match_global(end,1);
rvsalign_store.original_length = size(EEG_new.data,2);
rvsalign_store.begin_pad = length(beg_pad);
rvsalign_store.end_pad = length(end_pad);
structfn = ['/autofs/cifs/adsleepeeg/archive/subject_data/' subject_code '/clinical/' subject_code '_night' num2str(night) '_rvsalign.mat'];
save(structfn, 'rvsalign_store')


new_anno=SleepEEG_buildannot(fn_sleep);
signalCell_final{1,end}=new_anno;

edfFN=['/autofs/cifs/adsleepeeg/archive/subject_data/' subject_code '/clinical/' subject_code '_night' num2str(night) '_aligned.edf'];
[statusHeader statusSignalHeader statusSignalCell] = blockEdfWrite(edfFN, header_final,  signalHeader_final, signalCell_final);

end
%% Local Functions and Notes

%Pseudo Code
% 1. Pick Sharp increases in DC channel as triggers
% 2. Find time between triggers
% 3. Mark Start/End Sequences. Delete all triggers before/after these.
% 4. Match time between triggers. Construct times where triggers work. 
% 5. Stretch Sleep Recording to EEG Recording Times. 
% 6. Resample Sleep EEG so that it is at 500 Hz

function check_lengths(header, signalHeader, signalCell);
    for ii=1:length(signalHeader)
    end
end
