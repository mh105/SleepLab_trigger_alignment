function [resamp_trace, resamp_time, sleep_trace, sleep_time]=interp_to_eeg(match_global, compare_diff2, whole_trace, EEG_times)
%EEG_data should be EEG_new.data
%EEG_times should be EEG_new.times
%Resample function: 
%Inputs: 
% - match_global: matrix of interval # by 2. Index number of triggers. First
% column is eeg recording, second column is sleep recording.
% - compare_diff2: matrix of interval # by 4. Matched Intervals. First
% column is length of eeg time interval, second column is the length of
% sleep time interval that is matched to that. Third column is EEG time
% interval index, fourth is interval index of matched sleep times.
% - whole_trace is the sleep recoding matrix (rows are channels)
% - EEG_new.times is the time numbers from the EEG recording
    %attempted fix
    ind0=find(compare_diff2(:,2)==0);
    match_global(ind0,:)=[];
    compare_diff2(ind0,:)=[];

    [chan_no samp_no]=size(whole_trace);
    new_samp_no = match_global(end,1)-match_global(1,1)+1;
    resamp_trace=zeros(chan_no,new_samp_no);
    sleep_samp_no = match_global(end,2) - match_global(1,2)+1;
    sleep_time = zeros(1,sleep_samp_no);
    

        for jj=1:chan_no

            time_trace_500=[];
            if jj==1
                interval_eeg_all=[];
                sleep_time_stamp=[];
            end
            
            end_pt=[];
            end_pt_sleep=[];

            for ii=1:(length(match_global)-1) %23 and 170
                %interp each interval separately. Check time length with eeg intervals
                %and number of samples with sleep intervals, change time for sleep
                %samples to fit eeg length. Interp at EEG time stamps.
                %disp(['ii = ' num2str(ii)]);
                num_samp=match_global(ii+1,2)-match_global(ii,2); %number of samples
                time_stamp=[0:(num_samp-1)]*(compare_diff2(ii,1)/num_samp)*60*1000; %time_stamp in minute
                time_stamp=time_stamp+EEG_times(match_global(ii,1)); % in milliseconds
                interval_sleep=[match_global(ii,2):(match_global(ii+1,2)-1)];
                interval_eeg=EEG_times(match_global(ii,1):(match_global(ii+1,1)-1));
                %disp(ii)
                %match_global(ii,1)
                %match_global(ii+1,1)
                %size(interval_eeg)
                yq=interp1(time_stamp,whole_trace(jj,interval_sleep),interval_eeg);
                yq(isnan(yq))=0;
                if sum(isnan(yq))>0
                    disp(['Nan for interval ' num2str(ii) ' channel ' num2str(jj)]);
                end
                end_pt=[end_pt interval_eeg(1)];
                if jj==1
                    sleep_time_stamp=[sleep_time_stamp time_stamp];
                    interval_eeg_all=[interval_eeg_all interval_eeg];
                    if ii==length(match_global)-1
                        interval_eeg_all=[interval_eeg_all interval_eeg_all(end)+2];
                    end
                end
                time_trace_500=[time_trace_500 yq];
            end
            time_trace_500=[time_trace_500 whole_trace(jj,match_global(end,2))];

            sleep_trace(jj,:)=whole_trace(jj,match_global(1,2):(match_global(end,2)-1));
            sleep_time = sleep_time_stamp;
            resamp_trace(jj,:)=time_trace_500;
            resamp_time = interval_eeg_all;
        end


end