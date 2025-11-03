function [trigger_index_ds, trigger_index_orig] = identify_sleep_trig(DC_channel, Fs_orig, Fs_ds)
%transforming the square wave DC trigger channel into binary triggers. 
%input is the DC channel in a vector, in volts. Output is the index of where the
%triggers should be, the rising edge of the square wave.

    DC_samp_orig=length(DC_channel);
    DC_sec=DC_samp_orig/Fs_orig;
    
    %Length between triggers 
    time_lag = 0.5; %sec
    samp_lag = time_lag*Fs_orig;
    

    %check direction
    DC_max = max(DC_channel);
    DC_min = min(DC_channel);
    DC_sum = sum(DC_channel); %proportional to the integral. Should be positive.
    
    assert(DC_max>=0);
    assert(DC_sum>=0);
    
    DC_increase=diff(DC_channel);
    DC_increase=[0 DC_increase]; %matching indexes so that the trigger position will see an increase
    %May be unnecessary
    
    %find rising edge by tracking large increases
    increase_ind=find((DC_increase>1)); %using threshold of 1 Volt
    
    %% avoid triggers closer than 0.5 seconds together
        
    
    
    %% avoid multiple increases in a row. todo: Avoid triggers that are closer than
    %1 sec
    dist_bw_increase = diff(increase_ind);
    dist_bw_increase =[0 dist_bw_increase]; %matching indexes to delete later increases
    useable_trigs=(dist_bw_increase~=1); 
    trigger_index_orig=increase_ind(useable_trigs);
    
    %%
    trigger_index_ds = round(trigger_index_orig*Fs_ds/Fs_orig);
    
% holy shit I'm an idiot  
%     trig_binary=zeros(1,DC_samp_orig);
%     trig_binary(trigger_index_orig)=1;
%     
%     trig_upsamp=[];
%     
%     for ii=1:DC_samp_orig
%         trig_upsamp=[trig_upsamp trig_binary(ii)*ones(1,Fs_ds)];
%     end
%     
%     trigger_long_ds=[];
%     DC_samp_ds=length(trig_upsamp)/Fs_orig;
%     
%     for ii=1:DC_samp_ds
%         trig_temp=trig_upsamp(1,[((Fs_orig*(ii-1))+1):(Fs_orig*ii)]);
%         %disp(sum(trig_temp));
%         trigger_long_ds=[trigger_long_ds sum(trig_temp)];
%     end
%     
%     [trig_pks, trigger_index_ds] = findpeaks(trigger_long_ds);
    
    
end