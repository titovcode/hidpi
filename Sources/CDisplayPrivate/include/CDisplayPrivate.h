#ifndef CDisplayPrivate_h
#define CDisplayPrivate_h

#include <CoreGraphics/CGDirectDisplay.h>
#include <CoreGraphics/CGDisplayConfiguration.h>
#include <stdint.h>

// Layout of a display mode description as returned by the private
// CGSGetDisplayModeDescriptionOfLength API. 0xDC bytes total.
// Offsets verified against RDM (github.com/usr-sse2/RDM, MIT).
typedef union {
    uint8_t rawData[0xDC];
    struct {
        uint32_t mode;
        uint32_t flags;      // 0x4
        uint32_t width;      // 0x8
        uint32_t height;     // 0xC
        uint32_t depth;      // 0x10
        uint32_t dc2[42];
        uint16_t dc3;        // 0xBC
        uint16_t freq;       // 0xBE
        uint32_t dc4[4];
        float density;       // 0xD0 (2.0 == HiDPI)
    } derived;
} modes_D4;

// Private SkyLight/CoreGraphics symbols. Declared here; resolved at link
// time against CoreGraphics.framework.
extern void CGSGetCurrentDisplayMode(CGDirectDisplayID display, int *modeNum);
extern void CGSConfigureDisplayMode(CGDisplayConfigRef config, CGDirectDisplayID display, int modeNum);
extern void CGSGetNumberOfDisplayModes(CGDirectDisplayID display, int *nModes);
extern void CGSGetDisplayModeDescriptionOfLength(CGDirectDisplayID display, int idx, modes_D4 *mode, int length);

// Thin wrappers exposed to Swift.
int  hidpi_number_of_modes(CGDirectDisplayID display);
void hidpi_copy_all_modes(CGDirectDisplayID display, modes_D4 *outModes, int count);
int  hidpi_current_mode(CGDirectDisplayID display);
void hidpi_get_mode(CGDirectDisplayID display, int idx, modes_D4 *outMode);
int  hidpi_set_mode(CGDirectDisplayID display, int modeNum);

#endif /* CDisplayPrivate_h */
