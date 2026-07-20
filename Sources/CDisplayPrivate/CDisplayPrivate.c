#include "CDisplayPrivate.h"

int hidpi_number_of_modes(CGDirectDisplayID display) {
    int n = 0;
    CGSGetNumberOfDisplayModes(display, &n);
    return n;
}

void hidpi_copy_all_modes(CGDirectDisplayID display, modes_D4 *outModes, int count) {
    for (int i = 0; i < count; i++) {
        CGSGetDisplayModeDescriptionOfLength(display, i, &outModes[i], 0xD4);
    }
}

int hidpi_current_mode(CGDirectDisplayID display) {
    int m = 0;
    CGSGetCurrentDisplayMode(display, &m);
    return m;
}

void hidpi_get_mode(CGDirectDisplayID display, int idx, modes_D4 *outMode) {
    CGSGetDisplayModeDescriptionOfLength(display, idx, outMode, 0xD4);
}

int hidpi_set_mode(CGDirectDisplayID display, int modeNum) {
    CGDisplayConfigRef config;
    CGError err = CGBeginDisplayConfiguration(&config);
    if (err != kCGErrorSuccess) {
        return (int)err;
    }
    err = CGSConfigureDisplayMode(config, display, modeNum);
    if (err != kCGErrorSuccess) {
        CGCancelDisplayConfiguration(config);
        return (int)err;
    }
    return (int)CGCompleteDisplayConfiguration(config, kCGConfigurePermanently);
}
