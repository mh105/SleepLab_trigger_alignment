function [start_index, temp_index]= start_sequence(trig_diff,trig_index)
%temp_index is the index of the start triggers in the time interval vector
%start_index is the index of the start triggers in the DC vector.
    possible_start=find(trig_diff> 0.0332 & trig_diff<0.0335);
    temp_index=[];
    start_index=[];
    for ii=1:(length(possible_start)-2)
        if (possible_start(ii)+1==possible_start(ii+1)) && (possible_start(ii)+2 == possible_start(ii+2))
            temp_index=[temp_index [possible_start(ii); possible_start(ii+1); possible_start(ii+2); possible_start(ii+2)+1]];
            start_index=[start_index [trig_index(possible_start(ii)); trig_index(possible_start(ii+1)); trig_index(possible_start(ii+2)); trig_index(possible_start(ii+2)+1)]];
        end
    end
    %start_index=trig_index(temp_index);
end
