/* Copyright (c) 2026, Advanced Micro Devices, Inc.
 * SPDX-License-Identifier: BSD-3-Clause
 *
 * libmetal initialisation for the Python wrapper.
 *
 * libvrfdc does not call metal_init(): AMD's own examples do it themselves
 * before XVRFdc_InstanceInit. Without it libmetal's bus registry is
 * uninitialised, metal_device_open() fails, and XVRFdc_InstanceInit
 * dereferences the NULL device pointer it was just handed -- a segmentation
 * fault with nothing to point at the cause.
 *
 * This lives in C rather than in the cffi declarations because
 * METAL_INIT_DEFAULTS expands to a struct initialiser whose layout would
 * otherwise have to be mirrored by hand, and getting it wrong would be
 * another silent memory bug.
 */

/* xvrfdc.h, not <metal/init.h>: libmetal has no init.h, and the driver
 * header already pulls in the right libmetal declarations. It is also what
 * AMD's own examples include for exactly this call. */
#include "xvrfdc.h"

int xvrfdc_metal_init(void)
{
	struct metal_init_params init_param = METAL_INIT_DEFAULTS;

	return metal_init(&init_param);
}

void xvrfdc_metal_finish(void)
{
	metal_finish();
}
