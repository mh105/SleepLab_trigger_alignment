function [diff_mins]=trig_distances(trig_index, Fs)
    diff_trig=diff(trig_index);
    diff_mins=diff_trig/(Fs*60); %differences in minutes;
end
