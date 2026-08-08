function [eeg_input, edf_input] = initialize_alignment_inputs(EEG, eeg_Fs, edf_dc_trace, trigger_Fs, edf_Fs)
%INITIALIZE_ALIGNMENT_INPUTS Create the HD-EEG and clinical EDF input structs.

eeg_input = struct;
eeg_input.EEG = EEG;
eeg_input.Fs = eeg_Fs;

edf_input = struct;
edf_input.DC_trace = edf_dc_trace;
edf_input.trigger_Fs = trigger_Fs;
edf_input.Fs = edf_Fs;

end
