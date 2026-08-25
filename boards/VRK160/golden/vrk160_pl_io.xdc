# VRK160 PL I/O constraints
#
# The board's two push buttons are NOT taken from the `gpio_pb` board preset.
# gpio_pb_0/1 sit at BD37/BG35 with iostandard LVSTL05_10 -- they share I/O
# bank silicon with the LPDDR5 interface, which the golden's memory
# controllers own. Applying the board preset would have the board flow
# re-declare that bank and clash with the DDRMC; constraining the pins by hand
# (what AMD's own working VRK160 image does, via a "Custom" GPIO interface)
# does not.
#
# These constraints live in the golden so the boot partition claims the sites.
# In segmented configuration an overlay may not introduce IO the initial
# design does not use -- see Dfx 88-162 SegConfig-Validation-18.
set_property PACKAGE_PIN BD37       [get_ports {gpio_pb_tri_i[0]}]
set_property PACKAGE_PIN BG35       [get_ports {gpio_pb_tri_i[1]}]
set_property IOSTANDARD  LVSTL05_10 [get_ports {gpio_pb_tri_i[*]}]
