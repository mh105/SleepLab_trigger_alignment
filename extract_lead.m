function EEG_lead = extract_lead(EEG_trunc, EEG_label, channel_name)
    lead_chan=find(strcmp(EEG_label,channel_name));
    EEG_lead = EEG_trunc(lead_chan,:);
end