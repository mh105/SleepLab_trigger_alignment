function [sleep_output, eeg_output, sleep_input]=record_summary(sleep_input,eeg_input, signalHeader, header)
    %Inputs
    sleep_input.Fs=signalHeader(1).samples_in_record*(1/header.data_record_duration); %Is this in the data?
    
    %find triggers for EEG
    EEG=eeg_input.EEG;
    events = eeg_eventtable(EEG);
    latency = cell2mat(events{1,1}.values); %in samples
    [EEG_chan EEG_len]=size(EEG.data);
    
    
    %find triggers for sleep
    sleep_len=length(sleep_input.DC_trace);
    Fs=sleep_input.Fs;%HDR.SampleRate; %Is this wrong?
    %Labels=sleep_input.HDR.Label;
    %DC_channel_no=find(ismember(Labels,'DC8'));
    DC_channel_trace=sleep_input.DC_trace/1000000;%data(DC_channel_no,:)/1000000;
    [trigger_index_ds, trigger_index_orig]=identify_sleep_trig(DC_channel_trace',Fs,sleep_input.Fs_ds);
    
    
    %organize outputs
    %sleep_output.Fs_ds=sleep_input.Fs_ds;
    sleep_output.Fs=Fs;
    sleep_output.len_hr=sleep_len/(sleep_input.Fs_ds*60*60);
    %sleep_output.channels=Labels;
    sleep_output.trig_index=trigger_index_orig;
    sleep_output.DC_trace=DC_channel_trace;
    
    eeg_output.len_hr=EEG_len/(eeg_input.Fs*60*60);
    %EEG.times in milliseconds
    eeg_output.trig_index=latency(1:(end-1))'; %this creates time and not indexes %needs to start at 2 for normal eeg!
end