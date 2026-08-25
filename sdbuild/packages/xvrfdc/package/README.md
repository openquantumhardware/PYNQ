# xvrfdc

PYNQ driver for the **Versal RF Data Converter** (`vrf_data_converter`), the
Versal Gen 2 counterpart of the RFSoC `usp_rf_data_converter`.

It wraps AMD's `libvrfdc` (MIT) through CFFI, the same way `xrfdc` wraps the
RFSoC `rfdc` driver.

## Sources are not vendored

`libvrfdc` is MIT licensed but AMD publishes it only through their download
portal -- their own Yocto recipe fetches it from an internal git server. Set
`PYNQ_VRFDC_SRC` to the extracted driver directory before building:

    export PYNQ_VRFDC_SRC=/path/to/vrfdc-1.0-EA/XilinxProcessorIPLib/drivers/vrfdc

The build fails with an explanatory message if it is unset.

## Status

The upstream driver is Early Access. Of ~142 documented API calls, 76 are
ready, 28 partially ready and 38 not ready. This package wraps ready calls
only. Missing and significant: `SetDecimation`, `SetInterpolation`,
`SetFabWrWords`/`SetFabRdWords`, `SetFs`, and all of MTS. Configure those in
the Vivado design.

## IP version

Vivado 2025.2 ships `vrf_data_converter` v1.2. AMD released a v1.3 IP repo
out of band in June 2026 with more features, intended for use with 2025.2 --
add it as a User Repository and v1.2 disappears from the catalog. Both VLNVs
are in `bindto`.

Note that the v1.3 in Vivado 2026.1 is *not* the same IP as the v1.3 in that
repo; AMD flags this as a versioning error.
