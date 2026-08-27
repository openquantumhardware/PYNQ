/* CFFI cdef for libvrfdc.
 *
 * Hand-curated rather than generated: xvrfdc.h pulls in libmetal headers and
 * macros that cffi cannot parse. Only the subset actually wrapped below is
 * declared. Keep this in step with __init__.py.
 *
 * Types are flattened deliberately -- the opaque handles (metal_device,
 * metal_io_region) are never dereferenced from Python, so a void* stands in.
 */

typedef unsigned int   u32;
typedef unsigned short u16;
typedef unsigned char  u8;
typedef int            s32;
typedef unsigned long  metal_phys_addr_t;

typedef struct { u32 Major; u32 Minor; } XVRFdc_Version;

/* Opaque: allocated by cffi as a byte blob of the right size and only ever
 * passed back to the library. The size is asserted at import time. */
typedef struct { ...; } XVRFdc;

s32  XVRFdc_InstanceInit(XVRFdc *InstancePtr, metal_phys_addr_t BaseAddr, void **DevicePtr);
void XVRFdc_InstanceClose(XVRFdc *InstancePtr);

u32  XVRFdc_GetIPBaseAddr(XVRFdc *InstancePtr);
void XVRFdc_GetVersions(const XVRFdc *InstancePtr, XVRFdc_Version *SWVersion, XVRFdc_Version *IPVersion);

u32  XVRFdc_GetTileEnabled(XVRFdc *InstancePtr, u32 Type, u32 Tile_Id, u32 *EnabledPtr);
u32  XVRFdc_GetTileCurrentState(XVRFdc *InstancePtr, u32 Type, u32 Tile_Id, u32 *StatePtr);
u32  XVRFdc_GetTileCommonStatus(XVRFdc *InstancePtr, u32 Type, u32 Tile_Id, u32 *StatusPtr);

u32  XVRFdc_GetFabClkOutDiv(XVRFdc *InstancePtr, u32 Type, u32 Tile_Id, u16 *FabClkDivPtr);
u32  XVRFdc_GetFabWrWords(XVRFdc *InstancePtr, u32 Type, u32 Tile_Id, u32 Block_Id, u32 *FabricWrVldWordsPtr);
u32  XVRFdc_GetFabRdWords(XVRFdc *InstancePtr, u32 Type, u32 Tile_Id, u32 Block_Id, u32 *FabricRdVldWordsPtr);

/* Mixer / NCO.
 *
 * Declared field-for-field so cffi lays the struct out exactly as the
 * library does. Note NyquistZone lives here rather than behind a separate
 * Set/GetNyquistZone pair as in XRFdc -- on Versal it is part of the mixer
 * settings, which is the difference a QICK port has to bridge.
 */
typedef struct {
    u8     MixerType;
    u8     Band;
    double Freq;
    double PhaseOffset;
    u32    EventSource;
    u32    CoarseMixFreq;
    u32    MixerMode;
    u8     FineMixerScale;
    u8     NyquistZone;
    u8     ModeSelect;
} XVRFdc_Mixer_Settings;

u32  XVRFdc_SetMixerSettings(XVRFdc *InstancePtr, u32 Type, u32 Tile_Id, u32 Block_Id,
                             XVRFdc_Mixer_Settings *MixerSettingsPtr);
u32  XVRFdc_GetMixerSettings(XVRFdc *InstancePtr, u32 Type, u32 Tile_Id, u32 Block_Id,
                             u32 MixerType, u32 Band, XVRFdc_Mixer_Settings *MixerSettingsPtr);
