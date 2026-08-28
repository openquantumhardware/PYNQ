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

/* Three fields, not two. Declaring it short made XVRFdc_GetVersions write
 * 12 bytes into an 8-byte allocation and corrupt the heap:
 *   free(): invalid next size (fast)
 * Every struct here is copied field-for-field from xvrfdc.h for this
 * reason -- cffi trusts these declarations and cannot check them. */
typedef struct {
    u32 Major;
    u32 Minor;
    u32 Revision;
} XVRFdc_Version;

/* The driver instance is opaque here on purpose.
 *
 * It is NOT declared as a struct. xvrfdc.h wraps XVRFdc in #pragma pack(),
 * so its size cannot be derived from the field list, and cffi's partial
 * form -- typedef struct { ...; } XVRFdc; -- only works in API mode, where
 * cffi compiles against the real header. This module uses dlopen (ABI
 * mode), where that declaration cannot be sized and every ffi.new() for it
 * fails with
 *
 *     cffi.VerificationMissing: XVRFdc
 *
 * Instead the instance is a plain void*, and Python allocates a byte buffer
 * of exactly sizeof(XVRFdc) -- measured on the target at build time and
 * written into _size.py by the Makefile. Nothing here ever dereferences it.
 */

s32  XVRFdc_InstanceInit(void *InstancePtr, metal_phys_addr_t BaseAddr, void **DevicePtr);
void XVRFdc_InstanceClose(void *InstancePtr);

u32  XVRFdc_GetIPBaseAddr(void *InstancePtr);
void XVRFdc_GetVersions(const void *InstancePtr, XVRFdc_Version *SWVersion, XVRFdc_Version *IPVersion);

u32  XVRFdc_GetTileEnabled(void *InstancePtr, u32 Type, u32 Tile_Id, u32 *EnabledPtr);
u32  XVRFdc_GetTileCurrentState(void *InstancePtr, u32 Type, u32 Tile_Id, u32 *StatePtr);
u32  XVRFdc_GetTileCommonStatus(void *InstancePtr, u32 Type, u32 Tile_Id, u32 *StatusPtr);

u32  XVRFdc_GetFabClkOutDiv(void *InstancePtr, u32 Type, u32 Tile_Id, u16 *FabClkDivPtr);
u32  XVRFdc_GetFabWrWords(void *InstancePtr, u32 Type, u32 Tile_Id, u32 Block_Id, u32 *FabricWrVldWordsPtr);
u32  XVRFdc_GetFabRdWords(void *InstancePtr, u32 Type, u32 Tile_Id, u32 Block_Id, u32 *FabricRdVldWordsPtr);

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

u32  XVRFdc_SetMixerSettings(void *InstancePtr, u32 Type, u32 Tile_Id, u32 Block_Id,
                             XVRFdc_Mixer_Settings *MixerSettingsPtr);
u32  XVRFdc_GetMixerSettings(void *InstancePtr, u32 Type, u32 Tile_Id, u32 Block_Id,
                             u32 MixerType, u32 Band, XVRFdc_Mixer_Settings *MixerSettingsPtr);

/* From metal_shim.c -- see that file for why metal_init is not declared
 * directly. Must be called once before any device is opened. */
int  xvrfdc_metal_init(void);
void xvrfdc_metal_finish(void);
