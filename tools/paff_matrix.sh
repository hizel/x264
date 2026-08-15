# PAFF B-field regression matrix -- shared data, source'd by:
#   tools/test_paff.sh      (cmd_matrix: byte-exact JM round-trip)
#   tools/test_paff_ci.sh   (CI: encode-only smoke, no oracle)
#
# Carried from openspec/changes/archive/<date>-paff-b-frames/checkpoint-4.1-4.3.md
# (the "14/14 PAFF configs byte-exact" set).  A scripted matrix exists because
# that checkpoint's earlier "24/24 byte-exact" claim later did NOT reproduce on
# the same tree; pinning the configs makes the regression reproducible.
#
# Axis coverage: field order (TFF/BFF) x b-pyramid (none/normal/strict) x
# ref (1-4) x direct mode (none/spatial/temporal/auto) x entropy (CABAC/CAVLC)
# x keyint (8 for frame_num wrap, 24) x --no-deblock.  Several rows are the
# exact configs that previously segfaulted or drifted under PAFF:
#   mx05  -- the paff-b-frames --ref 1 crash + CAVLC + no-deblock
#   mx03  -- --b-pyramid strict --ref 2 BREF-eviction crash (task 5.1/2.4)
#   mx06  -- --ref 4 + --keyint 8 frame_num wrap
#   mx08  -- --no-deblock isolation of the bS deblock work (task 6.2)
#
# Each entry is NAME<TAB-PIPE>X264_OPTS.  --paff is added by the caller (every
# row is a PAFF config); opts use only flags valid for PAFF (no --weightb,
# which PAFF disables).
PAFF_MATRIX=(
    "mx01_tff_norm_r3_temp_cabac_ki24|--tff --bframes 3 --b-pyramid normal --ref 3 --direct temporal"
    "mx02_bff_norm_r3_temp_cabac_ki24|--bff --bframes 3 --b-pyramid normal --ref 3 --direct temporal"
    "mx03_tff_strict_r2_auto_cabac_ki24|--tff --bframes 3 --b-pyramid strict --ref 2 --direct auto"
    "mx04_tff_none_r3_spatial_cabac_ki24|--tff --bframes 3 --b-pyramid none --ref 3 --direct spatial"
    "mx05_tff_norm_r1_auto_cavlc_ki24_nodeblk|--tff --bframes 3 --b-pyramid normal --ref 1 --direct auto --no-cabac --no-deblock"
    "mx06_tff_norm_r4_none_cabac_ki8|--tff --bframes 3 --b-pyramid normal --ref 4 --direct none --keyint 8"
    "mx07_bff_strict_r3_temp_cavlc_ki8|--bff --bframes 3 --b-pyramid strict --ref 3 --direct temporal --no-cabac --keyint 8"
    "mx08_tff_norm_r3_temp_cabac_ki24_nodeblk|--tff --bframes 3 --b-pyramid normal --ref 3 --direct temporal --no-deblock"
    "mx09_tff_norm_r2_temp_cabac_ki24|--tff --bframes 3 --b-pyramid normal --ref 2 --direct temporal"
    "mx10_bff_norm_r2_spatial_cabac_ki24|--bff --bframes 3 --b-pyramid normal --ref 2 --direct spatial"
    "mx11_tff_none_r2_auto_cavlc_ki8|--tff --bframes 3 --b-pyramid none --ref 2 --direct auto --no-cabac --keyint 8"
    "mx12_bff_norm_r3_auto_cabac_ki8|--bff --bframes 3 --b-pyramid normal --ref 3 --direct auto --keyint 8"
    "mx13_tff_strict_r4_temp_cabac_ki8|--tff --bframes 3 --b-pyramid strict --ref 4 --direct temporal --keyint 8"
    "mx14_tff_norm_r3_spatial_cavlc_ki24|--tff --bframes 3 --b-pyramid normal --ref 3 --direct spatial --no-cabac"
)
